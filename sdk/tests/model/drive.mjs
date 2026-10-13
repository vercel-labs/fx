#!/usr/bin/env bun
// Drives real libfx, with its Zig kernel loaded through the native addon or
// WebAssembly, along paths of the TLC state graph of DurableSession.tla, and
// checks after every step that the code is in a state the model allows.
//
//   bun sdk/tests/model/drive.mjs [send|lookup|write|cutoff|leased|queue] [--walks N] [--seed S] [--backend native|wasm]
//     [--durability local|world|vercel]
//
// The lookup and cutoff graphs run a lookup, which starts before its intent
// is stored: the driver holds that intent's record, so the call runs while
// its intent is on its way, until the model's Intent step lets it land. The
// write graph runs an idempotent tool that writes, and the send graph a tool
// with effects; both wait for their intent. Each model response names a new
// call id, as a model's does, and the driver counts the execution ids the
// tool ran under.
//
// The leased graph is the send graph with Heartbeat: its agents keep the
// session in a World that cannot tell whether a holder runs, so each renews
// a 1 s lease. A freeze holds the worker's renewals until its lease runs
// out, and a wake lets them land.
//
// With --durability world each agent is given its own app-built World on the
// directory through world(), as servers with their own instances would (see
// sdk/tests/app-world.mjs).
//
// The queue graph is the send graph with QueueHeld: each agent's World has a
// queue that delivers as Vercel Queues does and no other sign of whether a
// worker lives (see sdk/tests/queue-world.mjs), so a worker holds the
// session for as long as its delivery holds its message. A freeze is the
// queue giving up on that delivery, and the Start that finds the frozen
// holder is that holder's message, delivered to the other agent. With --durability vercel the agents keep the
// session in Vercel's World (see sdk/tests/vercel-storage.mjs for what it
// needs) instead of files.
//
// `./check.sh` model-checks the spec and writes graphs/<graph>.dot; the cutoff
// graph runs lookup with more claims and no freezes, so a step can be cut off
// at the deadline until the bound stops running it. Each walk
// starts two agents, A and B, on one local() World directory. Every model
// request and tool call waits until the driver releases it, and so does each
// worker's claim on the session, so the driver decides the interleaving: it
// performs the step the walk chose, waits for the code to settle, reads back
// each worker's position, the tool runs, and the epoch of every UI line, and
// moves to the successor state that matches. A step the model has no
// matching successor for is a conformance failure.
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../node.js";
import { local } from "../../durable/local.mjs";
import { holdWrites } from "../hold-writes.mjs";
import { loadGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const graphName = args.find((arg) => ["send", "lookup", "write", "cutoff", "leased", "queue"].includes(arg)) ?? "send";
const tool = graphName === "cutoff" ? "lookup" : graphName === "leased" || graphName === "queue" ? "send" : graphName;
// The tool as the host declares it, and whether its calls run ahead.
const toolFlags = { lookup: { idempotent: true }, write: { idempotent: true, writes: true }, send: { idempotent: false } }[tool];
const runsAhead = tool === "lookup";
const walks = Number(option("walks", 40));
const backend = option("backend", "native");
const leased = graphName === "leased";
const durabilityKind = option("durability", leased ? "leased" : graphName === "queue" ? "queue" : "local");
if (!["local", "world", "vercel", "leased", "queue"].includes(durabilityKind)) throw new Error("--durability is local, world or vercel");
// Only the leased graph has the heartbeat's steps, and only its World renews
// leases; only the queue graph has a queue that shows whether a worker lives.
if (leased !== (durabilityKind === "leased")) throw new Error("the leased graph runs on its own World, and only it does");
if ((graphName === "queue") !== (durabilityKind === "queue")) throw new Error("the queue graph runs on its own World, and only it does");
// How long a leased worker's lease lasts after its last renewal.
const leaseMs = 1000;
const leasedWorld = leased ? await (async () => {
  const { createWorld } = await import(new URL("../../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
  const { world } = await import("../../durable/world.mjs");
  return (dir) => world(() => createWorld({ dataDir: dir, recoverActiveRuns: false }), { name: "leased", pollMs: 250, leaseMs });
})() : null;
// Vercel's World is a round trip away: settle, wait for streams, and give up
// on a step later.
const remote = durabilityKind === "vercel";
const settleMs = remote ? 1500 : 60;
const streamQuietMs = remote ? 2500 : 120;
const stepTimeoutMs = remote ? 30_000 : 5000;
const { vercelStorage } = remote ? await import("../vercel-storage.mjs") : {};
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../app-world.mjs") : {};
const queued = durabilityKind === "queue";
const { queueWorldAt, closeQueueWorlds } = queued ? await import("../queue-world.mjs") : {};
const verbose = args.includes("--verbose");
let seed = Number(option("seed", 1));
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const Workers = ["A", "B"];

// The epochs of the lines every reader shows, by the spec's ShownAt: each
// line no earlier line outranks.
const shownEpochs = (lines) => {
  let high = 0;
  const shown = [];
  for (const line of lines) {
    if (line.e < high) continue;
    high = line.e;
    shown.push(line.e);
  }
  return shown;
};
// What the driver compares: everything the code shows from outside. On the
// leased World, whether a lease stands too: a woken worker's renewal may or
// may not have landed, and only the lease tells those states apart.
const view = (state) => JSON.stringify({
  pc: state.pc, frozen: state.frozen, runs: state.runs, ids: state.ids, ui: shownEpochs(state.ui), ...(leased ? { live: state.live ?? state.lease.live } : {}),
});
const sameAct = (a, b) => a.name === b.name && a.w === b.w;

// ---------------------------------------------------------------------------
// The code under test: two agents on one World, with every model request and
// tool call held until the driver lets it go.

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const sse = (frames) => new Response(
  [...frames, "[DONE]"].map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const modeledLines = new Set(["turn_start", "turn_resume", "tool_start", "tool_end", "text_delta", "turn_yield", "turn_end"]);
const liveHolders = globalThis[Symbol.for("libfx.liveHolders")];
const durableInternals = Symbol.for("libfx.durableInternals");
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) return false;
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
  return true;
};
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));

// The ids of the calls a session-log record announces, from its stored
// journal events.
const intentCallIds = (entry) => {
  try {
    const { events } = JSON.parse(Buffer.from(entry.data, "base64").toString("utf8"));
    return events.filter((event) => event?.type === "tool_intent").flatMap((event) => event.data.map((call) => call.id));
  } catch {
    return [];
  }
};

// The queue as the driver runs it: a message the code asks to have delivered
// again later, as a backstop, is not, so nothing runs that the driver did not
// start. One handed back at a deadline still comes back at once.
function withoutBackstops(durability) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...args) => {
            const result = await handler(...args);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-model-"));
  const requests = [];
  const calls = [];
  const fenced = { A: 0, B: 0 };
  const holders = { A: [], B: [] };
  const claimed = { A: null, B: null };
  const frozen = { A: false, B: false };
  // Each worker's claims on the session: a holder's first lease waits until
  // the driver lets it land.
  const writes = {};
  // The renewals a frozen leased worker has not been let to write.
  const renewals = { A: [], B: [] };
  // On the queue's World: each agent's queue, and the message a frozen
  // holder's delivery held, which the queue delivers again.
  const brokers = {};
  const lapsed = { A: null, B: null };
  let runs = 0;
  // The execution ids the tool ran under, and the call ids whose first
  // intent was seen: a rerun announces its call again, and that record is
  // not held.
  const executions = new Set();
  const announced = new Set();
  let modelCalls = 0;
  // Each agent's events, for a failure.
  const events = [];
  let sessionId = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  const agents = {};
  for (const w of Workers) {
    const claims = new Set();
    // A queue-held lease runs to its worker's deadline, ten minutes away.
    const queueWorld = queued ? await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000 }) : null;
    if (queueWorld) brokers[w] = queueWorld.broker;
    const stored = leased ? leasedWorld(dir) : durabilityKind === "world" ? await appWorldAt(dir) : remote ? vercelStorage({ dir }) : queueWorld ? queueWorld.durability : local({ dir });
    const [durability, held] = holdWrites(withoutBackstops(stored), (entry) => {
      // The first intent of a call that runs ahead waits for the Intent step.
      if (entry.k === "record") {
        if (!runsAhead) return false;
        const fresh = intentCallIds(entry).filter((id) => !announced.has(id));
        for (const id of fresh) announced.add(id);
        return fresh.length > 0;
      }
      if (entry.k !== "lease") return false;
      if (!claims.has(entry.holder)) {
        claims.add(entry.holder);
        return true;
      }
      if (!frozen[w]) return false;
      renewals[w].push(entry);
      return true;
    });
    writes[w] = held;
    agents[w] = createFxAgent({
      backend,
      nativeAddon: addon,
      ...(wasm ? { wasm } : {}),
      apiKey: "model-key",
      model: "model/test",
      async fetch(input, init) {
        // The WebAssembly host passes a Request, the native one a URL and init.
        const request = input instanceof Request ? input : new Request(input, init);
        if (request.method === "GET") return Response.json({ object: "list", data: [{ id: "model/test", type: "language" }] });
        const prompt = JSON.parse(await request.text()).prompt;
        const signal = init?.signal ?? request.signal;
        return new Promise((resolveResponse, rejectResponse) => {
          const entry = { w, kind: toolResults(prompt).length > 0 ? "model2" : "model1", answer: (frames) => { remove(requests, entry); resolveResponse(sse(frames)); } };
          requests.push(entry);
          signal?.addEventListener("abort", () => { remove(requests, entry); rejectResponse(signal.reason ?? new Error("aborted")); }, { once: true });
        });
      },
      tools: [{
        name: tool,
        description: { send: "Sends an invoice", write: "Saves a key", lookup: "Looks up a key" }[tool],
        ...toolFlags,
        inputSchema: { type: "object", properties: { key: { type: "string" } } },
        execute: (input, { signal, executionId }) => {
          runs += 1;
          executions.add(executionId);
          return new Promise((resolveCall, rejectCall) => {
            const entry = { w, end: () => { remove(calls, entry); resolveCall(`value of ${input.key}`); } };
            calls.push(entry);
            signal?.addEventListener("abort", () => { remove(calls, entry); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
          });
        },
      }],
      durability,
      onEvent: (event) => {
        if (event.type === "session.fenced") fenced[w] += 1;
        if (!/^(acp|transport)\./.test(event.type)) events.push(`${w}:${event.type}${event.error ? `:${JSON.stringify(event.error)}` : ""}`);
      },
    });
  }

  async function streamLines(cursor = 0) {
    if (!sessionId) return [];
    const reader = agents.A.session(sessionId).stream(cursor).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), streamQuietMs); });
      const { value, done } = await Promise.race([reader.read(), quiet]);
      clearTimeout(timer);
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
    await reader.cancel().catch(() => {});
    return lines;
  }

  // Where each worker is, by what it waits on. A worker whose claim is held
  // may already wait on its first model request; one whose call's intent is
  // held runs that call ahead of it.
  const position = (w, lines) => {
    if (writes[w].held.some((entry) => entry.k === "lease" && !renewals[w].includes(entry))) return "early";
    if (claimed[w] === null) return "none";
    if (fenced[w] > claimed[w].fenced) return "stopped";
    if (lines.some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch)) return "done";
    const request = requests.find((entry) => entry.w === w);
    if (request) return request.kind;
    if (calls.some((entry) => entry.w === w)) return writes[w].held.some((entry) => entry.k === "record") ? "ahead" : "tool";
    return "busy";
  };
  const waiting = (w) => requests.some((entry) => entry.w === w) || calls.some((entry) => entry.w === w);
  const newHolders = (before) => [...liveHolders].filter((holder) => !before.has(holder));

  async function observe() {
    // Every worker now waits on the driver, but a line it wrote can still be
    // landing: read until two reads agree.
    let lines = await streamLines();
    for (let reads = 0; reads < 5; reads += 1) {
      const again = await streamLines();
      if (JSON.stringify(again) === JSON.stringify(lines)) break;
      lines = again;
    }
    // A reader that reconnects from any cursor sees the same lines after it.
    if (lines.length > 0) {
      const cursor = lines[Math.floor(random() * lines.length)].cursor;
      const again = await streamLines(cursor);
      const expected = lines.filter((line) => line.cursor > cursor);
      if (JSON.stringify(again) !== JSON.stringify(expected)) {
        // Which worker wrote what, and what each still waits on, tells a
        // line written late from one a read missed.
        const brief = (items) => items.map((line) => `${line.type}:e${line.epoch ?? 0}@${line.cursor}`).join(" ");
        const now = await streamLines();
        assert.fail([
          `reconnecting from cursor ${cursor} shows different lines`,
          `  first read: ${brief(lines)}`,
          `  reconnect:  ${brief(again)}`,
          `  read again: ${brief(now)}`,
          `  waiting: requests ${JSON.stringify(requests.map((entry) => `${entry.w}:${entry.kind}`))}, calls ${JSON.stringify(calls.map((entry) => entry.w))}, runs ${runs}, fenced ${JSON.stringify(fenced)}`,
        ].join("\n"));
      }
    }
    return {
      pc: Object.fromEntries(Workers.map((w) => [w, position(w, lines)])),
      frozen: { ...frozen },
      runs,
      ids: executions.size,
      ui: lines.filter((line) => modeledLines.has(line.type)).map((line) => line.epoch ?? 0),
      ...(leased ? { live: sessionId ? await agents.A[durableInternals].leaseStands(sessionId) : false } : {}),
    };
  }

  // One step of the model, done to the code.
  async function perform({ name, w }, expectedEpoch) {
    const stopped = () => claimed[w] !== null && fenced[w] > claimed[w].fenced;
    if (name === "Start") {
      // w receives work for the session; its claim waits for the driver.
      const before = new Set(liveHolders);
      // The queue hands on the message of a worker it gave up on, frozen or
      // woken since, while that worker still holds the session.
      const head = sessionId ? (await agents[w][durableInternals].lastLease(sessionId))?.holder : null;
      const handedOn = Workers.find((v) => v !== w && lapsed[v] && holders[v].includes(head));
      if (!sessionId) {
        const turn = agents[w].session().prompt(`use ${tool}`, { messageId: "turn-1" });
        void turn.result.catch(() => {});
        sessionId = (await turn.accepted).sessionId;
      } else if (handedOn) {
        // The queue hands the frozen holder's message to w.
        brokers[w].adopt(lapsed[handedOn]);
        lapsed[handedOn] = null;
      } else {
        void agents[w].session(sessionId).resume().result.catch(() => {});
      }
      await until(() => writes[w].held.length > 0);
      holders[w] = newHolders(before);
    } else if (name === "Claim") {
      // w's claim lands, and the log says whether it counted. One that did
      // goes on with the turn; a refused one leaves w to read the log again,
      // and to claim again or let the message go.
      const holder = writes[w].held.filter((entry) => entry.k === "lease").at(-1).holder;
      const before = new Set(liveHolders);
      await writes[w].releaseHeld();
      // A lease the World's in-band fence refused only because a count was
      // still settling goes out again, so the claim has settled once w holds
      // the session, holds a new write, or has let the session go.
      const holds = async () => (await agents[w][durableInternals].lastLease(sessionId))?.holder === holder;
      await until(async () => (await holds()) || writes[w].held.length > 0 || agents[w][durableInternals].liveWorkers() === 0);
      if (await holds()) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        await until(() => waiting(w) || stopped());
      } else {
        await until(() => writes[w].held.length > 0 || agents[w][durableInternals].liveWorkers() === 0);
        holders[w] = newHolders(before);
        claimed[w] = null;
      }
    } else if (name === "Model1" || name === "Model2") {
      const request = requests.find((entry) => entry.w === w);
      assert.ok(request, `${w} has a model request to answer`);
      // A response that calls the tool names a new call id, as a model's does.
      request.answer(name === "Model1"
        ? [{ type: "tool-call", toolCallId: `call-${(modelCalls += 1)}`, toolName: tool, input: { key: "alpha" } }, finish("tool-calls")]
        : [{ type: "text-delta", id: "answer", delta: "done" }, finish("stop")]);
      if (name === "Model1") await until(() => calls.some((entry) => entry.w === w) || stopped());
      else await until(async () => stopped() || (await streamLines()).some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch));
    } else if (name === "Intent") {
      // The intent of w's call that ran ahead lands. Where w still heads the
      // chain its call goes on; where it was replaced the write is refused,
      // and w stops.
      await writes[w].releaseHeld();
      const head = (await agents[w][durableInternals].lastLease(sessionId))?.holder;
      if (!holders[w].includes(head)) await until(() => stopped());
    } else if (name === "ToolEnd") {
      const call = calls.find((entry) => entry.w === w);
      assert.ok(call, `${w} has a tool call to end`);
      call.end();
      await until(() => requests.some((entry) => entry.w === w && entry.kind === "model2") || stopped());
    } else if (name === "Freeze") {
      // The platform gives up on w: its lease no longer counts as alive. A
      // leased worker's renewals are held until its lease runs out.
      for (const holder of holders[w]) liveHolders.delete(holder);
      frozen[w] = true;
      if (leased) await sleep(leaseMs + 400);
      // On the queue's World, the queue gives up on w's delivery; once w
      // holds the lease, the message comes back for the next Start.
      if (queued && holders[w].includes((await agents[w][durableInternals].lastLease(sessionId))?.holder)) {
        lapsed[w] = brokers[w].held((input) => input.sessionId === sessionId).filter((message) => message.attempt > 0).at(-1) ?? null;
      }
    } else if (name === "Wake") {
      frozen[w] = false;
      if (leased && renewals[w].length > 0) {
        // Its held renewals land: they keep its lease, or fence it out, and
        // a worker fenced out stops its turn.
        renewals[w] = [];
        await writes[w].releaseHeld();
        const head = (await agents[w][durableInternals].lastLease(sessionId))?.holder;
        if (claimed[w] && !holders[w].includes(head)) await until(() => stopped());
      }
    } else if (name === "Deadline") {
      // w's timer fires: it stops, and the same message comes back to it.
      const before = new Set(liveHolders);
      const fencedBefore = fenced[w];
      agents[w][durableInternals].stopAtDeadline(sessionId);
      const reclaimed = () => [...liveHolders].some((holder) => !before.has(holder));
      // The same message comes back to w, and its claim lands at once. Past
      // the bound, the step is not run again: a model request ends the turn.
      // A turn that ends lets the session go at once, so its claim is noted
      // when seen, and its end at the new epoch shows it too.
      const ended = async () => (await streamLines()).some((line) => line.type === "turn_end" && line.epoch === expectedEpoch);
      let took = false;
      await until(async () => {
        if (writes[w].held.length > 0) writes[w].releaseHeld();
        if (reclaimed()) took = true;
        if (writes[w].held.length > 0) return false;
        if (took && waiting(w)) return true;
        if (await ended()) return (took = true);
        return fenced[w] > fencedBefore;
      });
      if (took) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        holders[w] = [...liveHolders].filter((holder) => !before.has(holder));
      }
    }
    // Let background writes land before the code is read back.
    await sleep(settleMs);
  }

  async function close() {
    for (const w of Workers) writes[w].release();
    for (const entry of [...requests]) entry.answer([{ type: "error", errorText: "walk over" }]);
    for (const entry of [...calls]) entry.end();
    await Promise.race([Promise.all(Workers.map((w) => agents[w].close().catch(() => {}))), sleep(3000)]);
    await closeAppWorlds?.();
    await closeQueueWorlds?.();
    await rm(dir, { recursive: true, force: true });
  }

  // What the stream holds and what each worker waits on, for a failure.
  async function describe() {
    const lines = await streamLines();
    return [
      `  stream: ${lines.map((line) => `${line.type}:e${line.epoch ?? 0}${line.toolCallId ? `:${line.toolCallId}` : ""}`).join(" ")}`,
      ...lines.filter((line) => line.type === "turn_end").map((line) => `  ${JSON.stringify(line).slice(0, 400)}`),
      `  waiting: requests ${JSON.stringify(requests.map((entry) => `${entry.w}:${entry.kind}`))}, calls ${JSON.stringify(calls.map((entry) => entry.w))}, held ${JSON.stringify(Object.fromEntries(Workers.map((w) => [w, writes[w].held.map((entry) => entry.k)])))}, fenced ${JSON.stringify(fenced)}`,
      `  events: ${events.slice(-30).join(" ")}`,
    ].join("\n");
  }

  return { perform, observe, close, describe };
}

// ---------------------------------------------------------------------------
// Walks.

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "graphs", `${graphName}.dot`));
const covered = new Set();
const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + targets.size, 0);
let steps = 0;

const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const actOf = (id) => graph.states.get(id).act;

for (let walk = 1; walk <= walks; walk += 1) {
  const code = await harness();
  const path = [];
  // Every model state the code could be in, given all it has shown so far.
  let current = new Set([graph.init]);
  try {
    for (;;) {
      // The steps the driver can take. Announce follows at once in the code
      // whenever a worker claims, so the two are one step here.
      const options = [];
      for (const from of current) {
        for (const to of successors(from)) {
          const act = actOf(to);
          if (act.name === "Announce") continue;
          // local() hands a message that comes back at the deadline to the
          // same worker, so a Deadline that only releases the session is a
          // path the code cannot take.
          if (act.name === "Deadline" && graph.states.get(to).pc[act.w] === "none") continue;
          let option = options.find((item) => sameAct(item.act, act));
          if (!option) options.push(option = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) option.fresh = true;
        }
      }
      if (options.length === 0) break;
      const fresh = options.filter((option) => option.fresh);
      const pool = fresh.length > 0 ? fresh : options;
      const { act } = pool[Math.floor(random() * pool.length)];
      const expectedEpoch = act.name === "Claim" || act.name === "Deadline"
        ? Math.max(...[...current].flatMap((from) => successors(from).filter((to) => sameAct(actOf(to), act)).map((to) => graph.states.get(to).epoch[act.w])))
        : undefined;
      if (verbose) console.log(`walk ${walk}: ${act.name}(${act.w})`);
      await code.perform(act, expectedEpoch);
      path.push(`${act.name}(${act.w})`);
      steps += 1;
      // The states the step can reach, and the edges to each.
      const allowed = new Set();
      const reached = new Map();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const ends = graph.states.get(to).pc[act.w] === "announce"
            ? successors(to).filter((id) => sameAct(actOf(id), { name: "Announce", w: act.w })).map((id) => [to, id])
            : [[null, to]];
          for (const [middle, end] of ends) {
            const shown = view(graph.states.get(end));
            allowed.add(shown);
            if (!reached.has(shown)) reached.set(shown, []);
            reached.get(shown).push({ from, middle, end });
          }
        }
      }
      // A step's UI line is written after the step's other effects, and lines
      // are only ever appended: a view that matches no state yet is looked at
      // again for a while, and one that never does fails.
      let seen = JSON.stringify(await code.observe());
      for (let look = 0; !reached.has(seen) && look < 10; look += 1) {
        await sleep(100);
        seen = JSON.stringify(await code.observe());
      }
      if (verbose) console.log(`  shows ${seen}`);
      const next = new Set();
      for (const { from, middle, end } of reached.get(seen) ?? []) {
        next.add(end);
        covered.add(`${from}>${middle ?? end}`);
        if (middle) covered.add(`${middle}>${end}`);
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const view of allowed) console.error(`  the model allows ${view}`);
        console.error(await code.describe());
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.message}`);
    process.exitCode = 1;
  } finally {
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 25 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
if (!process.exitCode) console.log(`ok ${graphName}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend})`);
// An agent a failed walk left mid-turn keeps timers alive; nothing more runs.
process.exit(process.exitCode ?? 0);
