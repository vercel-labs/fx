// Runs the built fx binary along tests/tla/subagent/SteerQueue.tla: main's
// messages into its subagents' running turns (Owner.steer in
// src/core/subagent/managed_owner.zig).
//
// Each walk is one `fx ask` against a local fake gateway. The driver plays
// main's model and every subagent's model. Main's replies call the subagent
// tool: `message` to start an idle subagent or steer a working one, `stop`,
// and `close`. A subagent's model request is held until the driver lets it
// go: a tool call makes the subagent's next step read every waiting message,
// and a final answer ends its work. So the driver decides when each event
// happens, and fx decides what to answer.
//
// The walk is planned from the model's enabled actions (spec to code), and
// after every event the driver compares what fx answered with what the model
// predicts. Then TLC replays the whole run through the model's own actions
// (SteerQueueTrace.tla, code to spec). Messages that can't be refused go in
// one model step; one that the model may refuse goes alone, so the order fx
// handles them in never matters.
//
// Entries leave only at a new work and a close. With fx's trace on, the
// driver checks each start's `feedback_settled_dropped` count and each
// close's `feedback_forgotten` count against what the model holds for that
// subagent (SteerQueue.tla EntriesFromThisWork and ClosedHoldsNothing).
//
// The first walk, "lifetime", is fixed: 64 messages, read, then one more,
// which fx before the fix refused; a second subagent filled to exactly 64
// unread, one more refused, read, then one more accepted. The rest are seeded
// random walks. --self-check also replays the lifetime walk through the model
// of fx before the fix (Bug = "today"), which must reject it.
//
// --stress N starts --children subagents (20 by default in this mode) and
// sends each 30 messages per round for N rounds, reading after each round;
// it prints the wall time and fx's peak memory, and TLC checks the trace.
// --race N lets every subagent read while main's next messages go in, for N
// rounds; the order is not fixed, so instead of a trace it checks that every
// accepted message reaches its subagent exactly once and none is refused.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/subagent/driver.ts
//   bun tests/tla/drivers/subagent/driver.ts --self-check --random 8 --seed 7
//   bun tests/tla/drivers/subagent/driver.ts --random 0 --stress 10
//   bun tests/tla/drivers/subagent/driver.ts --random 0 --race 20 --children 6
//
// Exit codes: 0 every walk matched and TLC accepted it (and the self-check
// rejected), 1 fx answered something the model doesn't allow, 2 a toolchain,
// build, or harness failure.
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

const CAP = 64;
const MAIN_MARK = "DRIVER_MAIN";
// A long walk fills main's context, and fx compacts it mid-turn. That
// request is not one of main's steps; it gets plain notes, as the E2E tests'
// fake gateways give.
const COMPACTION_MARK = "You write compaction notes";

type Op = "start" | "steer" | "read" | "end" | "cancel" | "close";
type Planned = { op: Op; child: string };
type Event = { op: Op; child: string; predicted: string; result: string };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Call = { id: string; planned: Planned; predicted: string; text: string; input: object; kept?: number };

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

function parseOptions(argv: string[]) {
  const options = { random: 6, seed: 1, children: 0, ops: 80, jobs: 2, stress: 0, race: 0, selfCheck: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    const value = () => {
      const next = argv[++i];
      if (next === undefined || !/^\d+$/.test(next)) fail(2, `${arg} needs a number`);
      return Number(next);
    };
    if (arg === "--random") options.random = value();
    else if (arg === "--seed") options.seed = value();
    else if (arg === "--children") options.children = value();
    else if (arg === "--ops") options.ops = value();
    else if (arg === "--jobs") options.jobs = Math.max(1, value());
    else if (arg === "--stress") options.stress = value();
    else if (arg === "--race") options.race = value();
    else if (arg === "--self-check") options.selfCheck = true;
    else fail(2, `unknown option ${arg}`);
  }
  return options;
}

function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// The model's state and actions, as SteerQueue.tla with Bug = "none".
class Model {
  spawned = new Map<string, boolean>();
  running = new Map<string, boolean>();
  closed = new Map<string, boolean>();
  waiting = new Map<string, number>();
  settled = new Map<string, number>();
  constructor(public children: string[]) {
    for (const c of children) {
      this.spawned.set(c, false);
      this.running.set(c, false);
      this.closed.set(c, false);
      this.waiting.set(c, 0);
      this.settled.set(c, 0);
    }
  }
  enabled(op: Op, c: string): boolean {
    const running = this.running.get(c)!;
    const closed = this.closed.get(c)!;
    const waiting = this.waiting.get(c)!;
    switch (op) {
      case "start": return !running && !closed;
      case "steer": return running;
      case "read": return running && waiting > 0;
      case "end": return running && waiting === 0;
      case "cancel": return running;
      case "close": return this.spawned.get(c)! && !running && !closed;
    }
  }
  apply(op: Op, c: string): string {
    if (!this.enabled(op, c)) throw new Error(`${op} ${c} is not enabled`);
    const w = this.waiting.get(c)!;
    const s = this.settled.get(c)!;
    switch (op) {
      case "start":
        this.spawned.set(c, true);
        this.running.set(c, true);
        this.settled.set(c, 0);
        return "started";
      case "steer":
        if (w >= CAP) return "refused";
        this.waiting.set(c, w + 1);
        return "accepted";
      case "read":
        this.settled.set(c, s + w);
        this.waiting.set(c, 0);
        return "read";
      case "end":
        this.running.set(c, false);
        return "ended";
      case "cancel":
        this.running.set(c, false);
        this.settled.set(c, s + w);
        this.waiting.set(c, 0);
        return "cancelled";
      case "close":
        this.closed.set(c, true);
        this.settled.set(c, 0);
        return "closed";
    }
  }
}

function names(count: number): string[] {
  return Array.from({ length: count }, (_, i) => `c${i + 1}`);
}

// Ends every running subagent, reading first where messages wait.
function finish(model: Model, plan: Planned[]) {
  for (const c of model.children) {
    if (!model.running.get(c)) continue;
    if (model.waiting.get(c)! > 0) { model.apply("read", c); plan.push({ op: "read", child: c }); }
    model.apply("end", c);
    plan.push({ op: "end", child: c });
  }
}

function lifetimePlan(): { children: string[]; plan: Planned[] } {
  const children = names(2);
  const plan: Planned[] = [];
  const add = (op: Op, child: string, times = 1) => { for (let i = 0; i < times; i += 1) plan.push({ op, child }); };
  add("start", "c1"); add("steer", "c1", CAP); add("read", "c1");
  add("steer", "c1"); add("read", "c1"); add("end", "c1"); add("close", "c1");
  add("start", "c2"); add("steer", "c2", CAP + 1); add("read", "c2");
  add("steer", "c2"); add("read", "c2"); add("end", "c2");
  return { children, plan };
}

function randomPlan(seed: number, count: number, ops: number): { children: string[]; plan: Planned[] } {
  const children = names(count);
  const random = rng(seed);
  const model = new Model(children);
  const plan: Planned[] = [];
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  while (plan.length < ops) {
    const choices: Planned[] = [];
    for (const c of children) {
      for (const op of ["start", "steer", "steer", "steer", "read", "end", "cancel", "close"] as Op[]) {
        if (model.enabled(op, c)) choices.push({ op, child: c });
      }
    }
    if (choices.length === 0) break;
    const next = pick(choices);
    if (next.op === "steer") {
      // Bursts that stop short of the limit, reach it, or go past it.
      const room = CAP - model.waiting.get(next.child)!;
      const burst = pick([1, 2, 5, Math.max(1, room - 1), room, room + 1, room + 2]);
      for (let i = 0; i < burst; i += 1) { model.apply("steer", next.child); plan.push(next); }
    } else {
      model.apply(next.op, next.child);
      plan.push(next);
    }
  }
  finish(model, plan);
  return { children, plan };
}

function stressPlan(count: number, rounds: number): { children: string[]; plan: Planned[] } {
  const children = names(count);
  const model = new Model(children);
  const plan: Planned[] = [];
  const add = (op: Op, c: string) => { model.apply(op, c); plan.push({ op, child: c }); };
  for (const c of children) add("start", c);
  for (let r = 0; r < rounds; r += 1) {
    for (const c of children) for (let i = 0; i < 30; i += 1) add("steer", c);
    for (const c of children) add("read", c);
  }
  finish(model, plan);
  return { children, plan };
}

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

function classify(op: Op, text: string): string {
  if (op === "steer") {
    if (text.includes("Sent into the subagent's running turn")) return "accepted";
    if (text.includes("feedback_capacity")) return "refused";
  }
  if (op === "start" && text.includes("works on it now")) return "started";
  if (op === "cancel" && text.includes("Stopped")) return "cancelled";
  if (op === "close" && text.includes("Closed")) return "closed";
  return `other: ${text.slice(0, 160)}`;
}

const marker = (c: string, n: number) => `MSG-${c}-${String(n).padStart(5, "0")}`;

type Outcome = { events: Event[]; mismatch: Event | null; seconds: number; maxRss: number | null; exit: number | null; stderr: string; delivery: string[]; compactions: number };

// Runs one planned walk on the built fx. In race mode the plan is ignored
// and `race` rounds of concurrent reads and messages run instead.
async function runWalk(label: string, children: string[], plan: Planned[], scratch: string, race = 0): Promise<Outcome> {
  const helpers = await targetHelpers();
  const fakeModel: string = helpers.FAKE_GATEWAY_MODEL;
  const model = new Model(children);
  const events: Event[] = [];
  let mismatch: Event | null = null;
  const held = new Map<string, (response: Response) => void>();
  const arrivals = new Map<string, string[]>();
  const waiters = new Map<string, Array<(body: string) => void>>();
  const lastBody = new Map<string, string>();
  const unread = new Map<string, string[]>();
  const accepted = new Map<string, string[]>();
  const generation = new Map<string, number>();
  const sent = new Map<string, number>();
  const finishedSeen = new Map<string, number>();
  let index = 0;
  let pendingBatch: Call[] = [];
  let callSeq = 0;
  let home = "";
  let tracePath = "";
  const traceSeen = new Map<string, number>();

  const sse = helpers.fakeGatewaySse;
  const final = (text: string) => sse([{ type: "text-delta", id: "t", delta: text }, { type: "finish", finishReason: { unified: "stop", raw: "stop" } }]);
  const tools = (calls: Array<{ id: string; name: string; input: object }>) => sse([
    ...calls.map((call) => ({ type: "tool-call", toolCallId: call.id, toolName: call.name, input: call.input })),
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
  const readCall = (c: string) => tools([{ id: `read_${c}_${++callSeq}`, name: "glob_files", input: { pattern: "*" } }]);
  const arrive = (c: string, body: string) => {
    lastBody.set(c, body);
    const queue = waiters.get(c);
    if (queue && queue.length > 0) queue.shift()!(body);
    else arrivals.set(c, [...(arrivals.get(c) ?? []), body]);
  };
  const nextArrival = (c: string, ms = 30_000) => new Promise<string>((resolve, reject) => {
    const queued = arrivals.get(c);
    if (queued && queued.length > 0) { resolve(queued.shift()!); return; }
    const timer = setTimeout(() => reject(new Error(`${label}: ${c} sent no model request within ${ms} ms`)), ms);
    waiters.set(c, [...(waiters.get(c) ?? []), (body) => { clearTimeout(timer); resolve(body); }]);
  });
  // How many works of subagent `c` main's saved log has finished.
  const finishedCount = (c: string): number => {
    const root = join(home, ".fx", "sessions", "v2");
    if (!existsSync(root)) return 0;
    const ids = new Set<string>();
    let count = 0;
    for (const id of readdirSync(root)) {
      const log = join(root, id, "log.jsonl");
      if (!existsSync(log)) continue;
      const records = readFileSync(log, "utf8").split("\n").filter(Boolean).map((line) => {
        try { return JSON.parse(line); } catch { return {}; }
      });
      for (const r of records) if (r.kind === "child_spawned" && r.data?.agent === c) ids.add(r.child);
      for (const r of records) if (r.kind === "child_finished" && ids.has(r.child)) count += 1;
    }
    return count;
  };
  // fx's ids for subagent `c`, from main's saved log.
  const childIds = (c: string): Set<string> => {
    const ids = new Set<string>();
    const root = join(home, ".fx", "sessions", "v2");
    if (!existsSync(root)) return ids;
    for (const id of readdirSync(root)) {
      const log = join(root, id, "log.jsonl");
      if (!existsSync(log)) continue;
      for (const line of readFileSync(log, "utf8").split("\n")) {
        if (!line.includes("child_spawned")) continue;
        try {
          const r = JSON.parse(line);
          if (r.kind === "child_spawned" && r.data?.agent === c) ids.add(r.child);
        } catch {}
      }
    }
    return ids;
  };
  // The counts of every `event` trace line for subagent `c`.
  const traceCounts = (event: string, c: string): number[] => {
    if (!existsSync(tracePath)) return [];
    const ids = childIds(c);
    const counts: number[] = [];
    for (const match of readFileSync(tracePath, "utf8").matchAll(new RegExp(`event=${event} child_id=(\\S+) count=(\\d+)`, "g"))) {
      if (ids.has(match[1]!)) counts.push(Number(match[2]));
    }
    return counts;
  };
  // How many entries of `c` fx dropped at its last start or close, against
  // the `kept` entries the model holds. fx traces only a drop of one or more.
  const dropped = async (event: string, c: string, kept: number): Promise<number> => {
    const key = `${event} ${c}`;
    const before = traceSeen.get(key) ?? 0;
    const deadline = Date.now() + (kept > 0 ? 5_000 : 200);
    let counts = traceCounts(event, c);
    while (counts.length <= before && Date.now() < deadline) {
      await Bun.sleep(20);
      counts = traceCounts(event, c);
    }
    traceSeen.set(key, counts.length);
    return counts.length > before ? counts.at(-1)! : 0;
  };
  const awaitFinished = async (c: string) => {
    const before = finishedSeen.get(c) ?? 0;
    const deadline = Date.now() + 30_000;
    while (finishedCount(c) <= before) {
      if (Date.now() > deadline) throw new Error(`${label}: ${c}'s work never finished`);
      await Bun.sleep(20);
    }
    finishedSeen.set(c, before + 1);
  };
  const record = (planned: Planned, predicted: string, result: string) => {
    const event = { op: planned.op, child: planned.child, predicted, result };
    events.push(event);
    if (!mismatch && predicted !== result) {
      mismatch = event;
      console.error(`${label}: event ${events.length}, ${planned.op} ${planned.child}: fx ${str(result)}, model ${str(predicted)}`);
    }
  };
  // After a mismatch the walk stops: every held subagent ends, so fx ask
  // can deliver their reports and exit.
  const releaseAll = () => {
    for (const [c, resolve] of held) { held.delete(c); resolve(final(`DONE ${c}`)); }
  };
  const release = (c: string, response: Response) => {
    const resolve = held.get(c);
    if (!resolve) throw new Error(`${label}: ${c} has no held request`);
    held.delete(c);
    resolve(response);
  };

  // Child-side events run here, while main's request waits.
  const runChildEvent = async (planned: Planned) => {
    const c = planned.child;
    const predicted = model.apply(planned.op, c);
    if (planned.op === "read") {
      release(c, readCall(c));
      const body = await nextArrival(c);
      const missing = (unread.get(c) ?? []).filter((m) => !body.includes(m));
      unread.set(c, []);
      record(planned, predicted, missing.length === 0 ? "read" : `read_missing ${missing.length}`);
    } else {
      release(c, final(`DONE ${c}`));
      await awaitFinished(c);
      record(planned, predicted, "ended");
    }
  };

  const takeResults = async (body: string) => {
    for (const call of pendingBatch) {
      let result = classify(call.planned.op, toolResultText(body, call.id));
      const kept = call.kept ?? 0;
      if (call.planned.op === "close" && result === "closed") {
        const got = await dropped("feedback_forgotten", call.planned.child, kept);
        if (got !== kept) result = `closed, forgot ${got} of ${kept} entries`;
      }
      if (call.planned.op === "start" && result === "started") {
        const got = await dropped("feedback_settled_dropped", call.planned.child, kept);
        if (got !== kept) result = `started, dropped ${got} of ${kept} entries`;
      }
      const c = call.planned.child;
      if (call.planned.op === "start" && result === "started") await nextArrival(c);
      if (call.planned.op === "cancel" && result === "cancelled") {
        await awaitFinished(c);
        const resolve = held.get(c);
        held.delete(c);
        resolve?.(final("cancelled"));
        unread.set(c, []);
      }
      if (call.planned.op === "steer" && result === "accepted") {
        unread.set(c, [...(unread.get(c) ?? []), call.text]);
        accepted.set(c, [...(accepted.get(c) ?? []), call.text]);
      }
      record(call.planned, call.predicted, result);
    }
    pendingBatch = [];
  };

  const toolCall = (planned: Planned, predicted: string): Call => {
    const c = planned.child;
    let text = "";
    let input: object;
    if (planned.op === "start") {
      const g = (generation.get(c) ?? 0) + 1;
      generation.set(c, g);
      text = `TASK-${c}-${g} keep working until told`;
      input = { request: { action: "message", agent: c, message: text } };
    } else if (planned.op === "steer") {
      const n = (sent.get(c) ?? 0) + 1;
      sent.set(c, n);
      text = marker(c, n);
      input = { request: { action: "message", agent: c, message: `${text} note` } };
    } else {
      input = { request: { action: planned.op === "cancel" ? "stop" : "close", agent: c } };
    }
    return { id: `call_${++callSeq}`, planned, predicted, text, input };
  };
  const send = (batch: Call[]) => {
    pendingBatch = batch;
    return tools(batch.map((call) => ({ id: call.id, name: "subagent", input: call.input })));
  };

  // Race mode: every running subagent reads while main's messages go in.
  let raceRound = 0;
  const raceStep = async (): Promise<Response> => {
    if (raceRound === 0) {
      raceRound = 1;
      return send(children.map((c) => toolCall({ op: "start", child: c }, model.apply("start", c))));
    }
    if (raceRound <= race) {
      raceRound += 1;
      // Each subagent takes a step now, while the next messages go in.
      const reads = children.map((c) => { release(c, readCall(c)); return nextArrival(c); });
      const batch = children.flatMap((c) => Array.from({ length: 8 }, () => toolCall({ op: "steer", child: c }, "accepted")));
      await Promise.all(reads);
      return send(batch);
    }
    // Once: the subagents' reports wake main again after its final answer.
    if (raceRound > race + 1) return final("DRIVER_DONE");
    raceRound += 1;
    // Read until each subagent has seen every accepted message, then end it.
    for (const c of children) {
      for (let attempt = 0; attempt < 4; attempt += 1) {
        release(c, readCall(c));
        const body = await nextArrival(c);
        if ((accepted.get(c) ?? []).every((m) => body.includes(m))) break;
      }
      release(c, final(`DONE ${c}`));
      await awaitFinished(c);
    }
    return final("DRIVER_DONE");
  };

  const mainStep = async (body: string): Promise<Response> => {
    try {
      await takeResults(body);
      if (race > 0) return await raceStep();
      while (index < plan.length && !mismatch) {
        const planned = plan[index]!;
        if (planned.op === "read" || planned.op === "end") {
          index += 1;
          await runChildEvent(planned);
          continue;
        }
        // Main-side: messages the model accepts go together; anything else
        // goes alone.
        const batch: Call[] = [];
        while (index < plan.length) {
          const next = plan[index]!;
          if (next.op === "read" || next.op === "end") break;
          const kept = model.waiting.get(next.child)! + model.settled.get(next.child)!;
          const predicted = model.apply(next.op, next.child);
          batch.push({ ...toolCall(next, predicted), kept });
          index += 1;
          if (!(next.op === "steer" && predicted === "accepted")) break;
          const following = plan[index];
          if (!following || following.op !== "steer" || batch.length >= 200) break;
          // The next message might be refused: it goes in its own step.
          if (model.waiting.get(following.child)! >= CAP) break;
        }
        return send(batch);
      }
      releaseAll();
      return final("DRIVER_DONE");
    } catch (error) {
      if (!mismatch) {
        mismatch = { op: "end", child: "harness", predicted: "", result: String(error) };
        console.error(`${label}: ${String(error)}`);
      }
      releaseAll();
      return final("DRIVER_DONE");
    }
  };

  let compactions = 0;
  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    if (body.includes(COMPACTION_MARK)) {
      compactions += 1;
      return final("Main is running the driver's walk of subagent messages. Continue with the next step.");
    }
    if (body.includes(MAIN_MARK)) return await mainStep(body);
    const task = /TASK-(c\d+)-(\d+)/.exec(body);
    if (!task) return final("UNKNOWN_REQUEST");
    const c = task[1]!;
    if (mismatch) return final(`DONE ${c}`);
    return await new Promise<Response>((resolve) => {
      held.set(c, resolve);
      arrive(c, body);
    });
  }, { models: [{ id: fakeModel, type: "language", tags: ["tool-use"] }] });

  const root = mkdtempSync(join(scratch, `${label}-`));
  home = join(root, "home");
  tracePath = join(root, "trace.log");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  const started = performance.now();
  const child = Bun.spawn([binary, "ask", "--json", "--full-access", `${MAIN_MARK} run the walk`], {
    cwd: workspace,
    env: testEnvironment({
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-steer-queue-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: fakeModel,
      FX_MAX_AGENT_STEPS: "0",
      FX_TRACE_LOG: tracePath,
    }),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), 900_000);
  const [, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  for (const resolve of held.values()) resolve(final("closing"));
  gateway.stop();
  const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
  const maxRss = child.resourceUsage()?.maxRSS ?? null;
  // Race mode: each accepted message reaches its subagent exactly once.
  const delivery: string[] = [];
  if (race > 0) {
    for (const c of children) {
      const last = lastBody.get(c) ?? "";
      for (const m of accepted.get(c) ?? []) {
        const times = last.split(m).length - 1;
        if (times !== 1) delivery.push(`${m} reached ${c} ${times} times`);
      }
    }
    for (const e of events) if (e.op === "steer" && e.result !== "accepted") delivery.push(`${e.child} refused a message: ${e.result}`);
  }
  rmSync(root, { recursive: true, force: true });
  return { events, mismatch, seconds, maxRss, exit, stderr: stderr.slice(-2000), delivery, compactions };
}

const str = (value: string) => JSON.stringify(value);

function observedModule(events: Event[]): string {
  const rows = events.map((e) => `[op |-> ${str(e.op)}, child |-> ${str(e.child)}, result |-> ${str(e.result)}]`);
  return ["---- MODULE SteerQueueObserved ----", "EXTENDS Sequences", `Observed == <<${rows.join(",\n  ")}>>`, "====", ""].join("\n");
}

async function runTrace(events: Event[], children: string[], bug: string, parent: string): Promise<Verdict> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  const tlaDir = join(TLA_ROOT, "subagent");
  for (const file of ["SteerQueue.tla", "SteerQueueTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "SteerQueueObserved.tla"), observedModule(events));
  const steers = events.filter((e) => e.op === "steer").length;
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Children = {${children.map(str).join(", ")}}`,
    `  Cap = ${CAP}`,
    `  MaxSends = ${steers + 1}`,
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "SteerQueueTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return "ACCEPTED";
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return "REJECTED";
  console.error(`TLC tool error in ${dir} (exit ${code})`);
  return "TOOL_ERROR";
}

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (!existsSync(binary)) fail(2, `missing ${binary}; run zig build first`);
  const out = outDir("subagent-steer-queue");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  console.log(`artifacts: ${out}`);

  type Walk = { label: string; children: string[]; plan: Planned[]; race: number };
  const walks: Walk[] = [];
  if (options.stress === 0 && options.race === 0) walks.push({ label: "lifetime", ...lifetimePlan(), race: 0 });
  for (let i = 0; i < options.random; i += 1) {
    const seed = options.seed + i;
    walks.push({ label: `seed-${seed}`, ...randomPlan(seed, options.children || 2, options.ops), race: 0 });
  }
  if (options.stress > 0) walks.push({ label: `stress-${options.stress}`, ...stressPlan(options.children || 20, options.stress), race: 0 });
  if (options.race > 0) walks.push({ label: `race-${options.race}`, children: names(options.children || 6), plan: [], race: options.race });

  const results: Array<Walk & Outcome & { verdict?: Verdict }> = [];
  let next = 0;
  const worker = async () => {
    while (next < walks.length) {
      const walk = walks[next++]!;
      const outcome = await runWalk(walk.label, walk.children, walk.plan, scratch, walk.race);
      results.push({ ...walk, ...outcome });
      const refused = outcome.events.filter((e) => e.result === "refused").length;
      const peak = outcome.maxRss ? `${Math.round(outcome.maxRss / 1024 / 1024)} MiB` : "unknown";
      console.log(`${walk.label}: ${outcome.events.length} events, ${refused} refused, ${outcome.compactions} compactions, ${outcome.seconds}s, peak memory ${peak}, fx exit ${outcome.exit}`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(options.jobs, walks.length) }, worker));
  writeJson(join(out, "walks.json"), results.map(({ plan, ...rest }) => ({ ...rest, plan_length: plan.length })));

  let bad = false;
  for (const r of results) {
    if (r.mismatch) {
      bad = true;
      console.error(`${r.label}: fx answered ${str(r.mismatch.result)} to ${r.mismatch.op} ${r.mismatch.child}; the model predicts ${str(r.mismatch.predicted)} (event ${r.events.indexOf(r.mismatch) + 1})`);
      continue;
    }
    if (r.race > 0) {
      if (r.delivery.length > 0) { bad = true; console.error(`${r.label}: ${r.delivery.slice(0, 5).join("; ")}`); }
      else console.log(`${r.label}: every accepted message reached its subagent exactly once`);
      continue;
    }
    r.verdict = await runTrace(r.events, r.children, "none", out);
    console.log(`${r.label}: TLC ${r.verdict}`);
    if (r.verdict === "TOOL_ERROR") fail(2, "TLC could not check the trace");
    if (r.verdict !== "ACCEPTED") bad = true;
  }
  if (options.selfCheck) {
    const life = results.find((r) => r.label === "lifetime");
    if (!life || life.mismatch) fail(2, "--self-check needs a matched lifetime walk");
    const today = await runTrace(life.events, life.children, "today", out);
    console.log(`self-check: the model of fx before the fix ${today === "REJECTED" ? "rejects" : "accepts"} the lifetime walk`);
    if (today !== "REJECTED") bad = true;
  }
  process.exit(bad ? 1 : 0);
}

await main();
