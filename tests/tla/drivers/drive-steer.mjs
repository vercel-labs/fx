#!/usr/bin/env bun
// Drives real libfx, with its Zig kernel loaded through the native addon or
// WebAssembly, along paths of the TLC state graph of DurableSteer.tla, and
// checks after every step that the code is in a state the model allows.
//
//   bun tests/tla/drivers/drive-steer.mjs [ideal|faults] [--walks N] [--seed S]
//     [--backend native|wasm] [--durability local|world] [--verbose] [--hooks]
//
// `tests/tla/sdk/check.sh` model-checks the spec and writes its
// graphs/steer-<graph>.dot. The
// ideal graph has no faults; the faults graph adds cancels, deadline handoffs
// and client retries.
//
// Each walk starts one agent on a fresh local() World directory. Every model
// request streams only what the driver sends it, every tool call waits until
// the driver ends it, each queue delivery waits until the driver lets it
// run, a call that a reply ends in starts only once the driver lets its
// intent be stored, and a turn whose last read found nothing ends only once
// the driver lets its end record be stored, so the driver decides the
// interleaving. Where the model
// lets a step end in more than one state, the walk aims for one of them and
// the driver brings it about. After each step it reads back what the model was sent, in the newest request, which
// carries the whole conversation: a message that started a turn on the
// session's stream opens that turn, and every other message joins the turn
// before it. With how each turn ended, from the stream, and what the model is
// doing now, that is the state the driver compares with the model's.
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../../sdk/node.js";
import { local } from "../../../sdk/durable/local.mjs";
import { loadGraph } from "./graph.mjs";
import { testHooks } from "../../../sdk/tests/hooks-fixture.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const graphName = args.find((arg) => ["ideal", "faults"].includes(arg)) ?? "ideal";
const walks = Number(option("walks", 30));
const backend = option("backend", "native");
const durabilityKind = option("durability", "local");
if (!["local", "world"].includes(durabilityKind)) throw new Error("--durability is local or world");
const verbose = args.includes("--verbose");
let seed = Number(option("seed", 1));
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
const durableInternals = Symbol.for("libfx.durableInternals");
const stepTimeoutMs = 8000;
// How long the code must show the same state before the driver reads it.
const quietMs = 250;
// A running worker sees a new input when it next reads the log, which a
// local() World has it do every 250 ms; the driver waits that out after
// sending one before it reads the code.
const inputMs = 400;

// What each message says, so a request shows which messages it carries.
const textOf = (m) => (m === "p" ? "prompt p" : `steer ${m}`);
const messageIn = (text) => /\b(?:prompt (p)|steer (s\d+))\b/.exec(text)?.slice(1).find(Boolean) ?? null;
const steering = (text) => text.startsWith("<user_steering>");

// ---------------------------------------------------------------------------
// The state graph TLC wrote.

const sorted = (items) => [...items].sort();
// What the driver compares: what the model was sent, how each turn ended,
// and what the model is doing now.
const view = (state) => {
  const turns = state.turns.filter((turn) => turn.state !== "waiting");
  const placed = new Set(turns.flatMap((turn) => turn.ctx));
  return JSON.stringify({
    turns: turns.map((turn) => ({ owner: turn.owner, state: turn.state, ctx: sorted(turn.ctx) })),
    phase: state.phase,
    twice: sorted(state.dup.filter((m) => placed.has(m))),
  });
};
const sameAct = (a, b) => a.name === b.name && a.m === b.m;

// ---------------------------------------------------------------------------
// The code under test.

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const encoder = new TextEncoder();
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) return false;
    await sleep(5);
  }
  return true;
};

// The queue as the driver runs it. Each delivery waits until the driver lets
// it run, as one does while the platform has not delivered it yet; every
// input reaches the log when it is sent, before its delivery, so only when a
// worker starts waits. A message the code asks to have delivered again later,
// as a backstop, is not, so nothing runs that the driver did not start.
//
// While `reads.holding`, every read of the session log through this World
// waits until the driver lets it go, so the worker does not read a steer the
// model has as unread before the model's Read, ToolEnd or ModelText.
//
// While `records.holding`, the engine's journal records wait to be stored,
// and inputs do not. A call with effects starts only once its intent is
// stored, so holding them keeps a reply that ended in such a call in `call`.
//
// While `ends.holding`, the record that ends a turn waits to be stored, and
// the records before it do not. The turn's last read of the log has run by
// then, so holding it keeps the turn `ending`.
function gatedDeliveries(durability, gate, reads, records, ends) {
  const decoder = new TextDecoder();
  const entryOf = (event) => {
    const input = event?.eventData?.input;
    if (!(input instanceof Uint8Array)) return null;
    try { return JSON.parse(decoder.decode(input)); } catch { return null; }
  };
  const endsTurn = (entry) => (entry?.marks ?? []).some((mark) => mark?.end === true);
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      const events = new Proxy(world.events, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key === "list") {
            return async (...listArgs) => {
              if (reads.holding) await new Promise((go) => reads.held.push(go));
              return value.call(target, ...listArgs);
            };
          }
          if (key === "create") {
            return async (runId, event, ...rest) => {
              const entry = entryOf(event);
              if (entry?.k === "record") {
                if (endsTurn(entry)) await ends.pass();
                await records.pass();
              }
              return value.call(target, runId, event, ...rest);
            };
          }
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      return new Proxy(world, {
        get(target, key) {
          if (key === "events") return events;
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...handlerArgs) => {
            await gate.wait();
            const result = await handler(...handlerArgs);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

// Another server's World on the same store, whose queue sends nothing: a
// steer it stores reaches the running worker only through the log.
function storeOnly(durability) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          if (key === "queue") return async () => ({});
          const value = Reflect.get(target, key);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
    },
  };
}

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-steer-model-"));
  // Every model request so far, and the open ones.
  const requests = [];
  const open = [];
  const calls = [];
  let toolCalls = 0;
  let sessionId = null;
  let session = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  // Every tool call runs until the driver ends it.
  const held = (result, { signal } = {}) => new Promise((resolveCall, rejectCall) => {
    const entry = { aborted: false, end: () => { remove(calls, entry); resolveCall(result); } };
    calls.push(entry);
    signal?.addEventListener("abort", () => { entry.aborted = true; remove(calls, entry); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
  });
  // Deliveries the driver has not let run yet.
  const gate = {
    held: [],
    open: false,
    wait() { return gate.open ? Promise.resolve() : new Promise((go) => gate.held.push(go)); },
    release() { for (const go of gate.held.splice(0)) go(); },
  };
  // The worker's log reads the driver holds, and whether it holds new ones.
  const reads = {
    holding: false,
    held: [],
    release() {
      reads.holding = false;
      for (const go of reads.held.splice(0)) go();
    },
  };
  // Journal records the driver keeps from being stored, which holds a call
  // with effects before it starts.
  const records = {
    holding: false,
    held: [],
    pass() { return records.holding ? new Promise((go) => records.held.push(go)) : Promise.resolve(); },
    release() {
      records.holding = false;
      for (const go of records.held.splice(0)) go();
    },
  };
  // The record that ends a turn, which the driver keeps from being stored to
  // hold the turn `ending`.
  const ends = {
    holding: false,
    held: [],
    pass() { return ends.holding ? new Promise((go) => ends.held.push(go)) : Promise.resolve(); },
    release() {
      ends.holding = false;
      for (const go of ends.held.splice(0)) go();
    },
  };
  const stored = durabilityKind === "world" ? await appWorldAt(dir) : local({ dir });
  const durability = gatedDeliveries(stored, gate, reads, records, ends);
  // The request right after a tool's result, which ToolEnd compares.
  let pinned = null;
  const options = {
    ...(testHooks ? { hooks: testHooks } : {}),
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
      const users = prompt.filter((message) => message.role === "user").map((message) => (typeof message.content === "string"
        ? message.content
        : message.content.filter((part) => part.type === "text").map((part) => part.text).join("")));
      let controller;
      const body = new ReadableStream({ start(stream) { controller = stream; } });
      const entry = {
        users,
        phase: "gen",
        aborted: false,
        send(frames) {
          for (const frame of frames) controller.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`));
        },
        end(frames) {
          this.send(frames);
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
          remove(open, this);
        },
      };
      requests.push(entry);
      open.push(entry);
      signal?.addEventListener("abort", () => {
        entry.aborted = true;
        remove(open, entry);
        try { controller.error(signal.reason ?? new Error("aborted")); } catch {}
      }, { once: true });
      // The reply starts streaming text at once, as a model's does.
      entry.send([{ type: "text-delta", id: "reply", delta: "w " }]);
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    },
    tools: [{
      name: "lookup",
      description: "Looks up a key",
      idempotent: true,
      inputSchema: { type: "object", properties: { key: { type: "string" } } },
      execute: (toolInput, context) => held(`value of ${toolInput.key}`, context),
    }, {
      // A call with effects, which starts only once its intent is stored.
      name: "email",
      description: "Sends an email",
      idempotent: false,
      inputSchema: { type: "object", properties: { to: { type: "string" } } },
      execute: (toolInput, context) => held(`sent to ${toolInput.to}`, context),
    }, {
      // A call that is safe to run twice and writes, which also starts only
      // once its intent is stored, and runs again when a deadline cut it off.
      name: "save",
      description: "Saves a note",
      idempotent: true,
      writes: true,
      inputSchema: { type: "object", properties: { note: { type: "string" } } },
      execute: (toolInput, context) => held(`saved ${toolInput.note}`, context),
    }],
  };
  const agent = createFxAgent({ ...options, durability });
  // Another server on the same store. A steer the model leaves unread comes
  // from it, so the worker hears of it only by reading the log, as the
  // model's `unread` has it.
  const sender = createFxAgent({ ...options, durability: storeOnly(durabilityKind === "world" ? await appWorldAt(dir) : local({ dir })) });

  async function streamLines() {
    if (!sessionId) return [];
    const reader = agent.session(sessionId).stream(0).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), 120); });
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

  async function read() {
    // How each turn the stream shows ended, by the message that owns it.
    const lines = await streamLines();
    const ownerOf = new Map();
    const ended = new Map();
    for (const line of lines) {
      if (line.type === "turn_start") ownerOf.set(line.messageId, messageIn(line.input ?? ""));
      if (line.type === "turn_end") ended.set(line.messageId, line.stopReason === "cancelled" ? "cancelled" : "end");
    }
    const stateOf = new Map();
    for (const [messageId, owner] of ownerOf) if (owner) stateOf.set(owner, ended.get(messageId) ?? "running");
    // The turns the model was sent, from the newest request: a message that
    // started a turn on the stream opens it, and every other message joins
    // the turn before it. A steer that joined a turn reaches the model as a
    // live update, a resumed turn's too, but the stream, not the text, says
    // who owns a turn.
    // After a tool's result, the request right after it: a steer that
    // reaches only a later one missed it (API-53).
    const turns = [];
    const counts = new Map();
    for (const text of (pinned === null ? requests.at(-1) : requests[pinned])?.users ?? []) {
      const m = messageIn(text);
      if (!m) continue;
      counts.set(m, (counts.get(m) ?? 0) + 1);
      if (stateOf.has(m) && !steering(text) && !turns.some((turn) => turn.owner === m)) turns.push({ owner: m, ctx: new Set([m]) });
      else turns.at(-1)?.ctx.add(m);
    }
    // A reply that ended in a call with effects is in `call` while its intent
    // waits to be stored and the tool has not started, and a turn is
    // `ending` while the record that ends it waits.
    const phase = calls.length > 0 ? "tool"
      : records.held.length > 0 ? "call"
        : ends.held.length > 0 ? "ending"
          : open.length > 0 ? open.at(-1).phase : "idle";
    return JSON.stringify({
      turns: turns.map((turn) => ({ owner: turn.owner, state: stateOf.get(turn.owner) ?? "running", ctx: sorted(turn.ctx) })),
      phase,
      twice: sorted([...counts].filter(([, count]) => count > 1).map(([m]) => m)),
    });
  }

  // The code has settled when it shows the same state for quietMs.
  async function observe() {
    let seen = await read();
    const started = Date.now();
    for (;;) {
      await sleep(quietMs);
      const again = await read();
      if (again === seen) break;
      seen = again;
      if (Date.now() - started > stepTimeoutMs) break;
    }
    if (verbose) {
      for (const [index, request] of requests.entries()) {
        const sent = request.users.map((text) => `${steering(text) ? "~" : ""}${messageIn(text) ?? "?"}`).join(" ");
        console.log(`    request ${index + 1}: ${sent}${request.aborted ? " (aborted)" : ""}${open.includes(request) ? ` (open, ${request.phase})` : ""}`);
      }
    }
    return seen;
  }

  // What the user sends: a message, the same steer again, or a cancel.
  // `aim` is the model's state the step should end in.
  async function performInput({ name, m }, aim) {
    if (name === "Cancel") {
      reads.release();
      await session.cancel();
      // A turn cancelled in `call` stores how it ended, and one cancelled
      // while `ending` stores its end.
      records.release();
      ends.release();
    } else if (m === "p") {
      session = agent.session();
      const turn = session.prompt(textOf("p"), { messageId: "p" });
      void turn.result.catch(() => {});
      sessionId = (await turn.accepted).sessionId;
      await until(() => gate.held.length > 0);
    } else if (ends.held.length > 0 && !reads.holding && random() < 0.5) {
      // A steer sent while the turn's end lands, from this agent, whose
      // worker hears of it at once and hands it on; the turn takes no more
      // steers, so it stays stored, as the model's unread steer does. The
      // other times it comes from the other server.
      if (verbose) console.log("    from this agent while the turn's end lands");
      await session.steer(textOf(m), { messageId: m });
    } else if (aim.unread.includes(m) || reads.holding) {
      // A steer the model has unread comes from the other server, and the
      // worker reads nothing until the model's Read, so only a read it makes
      // itself, before a tool's result goes on or before the turn ends, can
      // find the steer. While a reply streams, that is how a steer another
      // server sends near the reply's end reaches the turn. While reads are
      // held, every steer comes from there, as this agent's own reads wait.
      reads.holding = true;
      await sender.session(sessionId).steer(textOf(m), { messageId: m });
    } else {
      // The steer's own id, which libfx before identities ignores.
      await session.steer(textOf(m), { messageId: m });
    }
  }

  // One step of the model, done to the code, which should end in the
  // model's state `aim`.
  async function perform({ name, m }, aim) {
    pinned = null;
    if (name === "Send" || name === "Retry" || name === "Cancel") {
      await performInput({ name, m }, aim);
      await sleep(inputMs);
      return;
    }
    if (name === "Read") {
      // The worker's next poll reads the log.
      reads.release();
      await sleep(inputMs);
    } else if (name === "Start") {
      reads.release();
      gate.release();
      await until(() => open.length > 0);
    } else if (name === "ModelText") {
      // Reads made from now on go through, so the worker's read before the
      // turn ends finds the steers it had not read; the polls held before go
      // only once the next request is out, which the view then shows. A turn
      // that read nothing more has its end record held, so it stays
      // `ending`.
      reads.holding = false;
      const at = requests.length;
      if (aim.phase === "ending") ends.holding = true;
      open.at(-1).end([{ type: "text-delta", id: "reply", delta: "done" }, finish("stop")]);
      if (aim.phase === "gen") await until(() => requests.length > at && open.length > 0);
      if (aim.phase === "ending") await until(() => ends.held.length > 0);
      reads.release();
    } else if (name === "EndLands") {
      // The record that ends the turn lands; a turn of the steers stored
      // since starts in the same delivery.
      reads.release();
      const at = requests.length;
      ends.release();
      if (aim.phase === "gen") await until(() => requests.length > at && open.length > 0);
    } else if (name === "ToolArgs") {
      const request = open.at(-1);
      toolCalls += 1;
      request.toolId = `call-${toolCalls}`;
      request.phase = "args";
      request.send([
        { type: "tool-input-start", id: request.toolId, toolName: "lookup" },
        { type: "tool-input-delta", id: request.toolId, delta: "{\"key\":\"al" },
      ]);
    } else if (name === "ReplyCall") {
      // The reply ends in a call it streamed no arguments for, one with
      // effects or one safe to run twice that writes, which a deadline in
      // `call` resumes differently; its intent is held, so the tool waits to
      // start.
      const request = open.at(-1);
      toolCalls += 1;
      records.holding = true;
      const call = random() < 0.5 ? { toolName: "email", input: { to: "alpha" } } : { toolName: "save", input: { note: "alpha" } };
      request.end([
        { type: "tool-call", toolCallId: `call-${toolCalls}`, ...call },
        finish("tool-calls"),
      ]);
      await until(() => records.held.length > 0);
    } else if (name === "ToolCall" && records.holding) {
      // The call's intent is stored and the tool starts.
      records.release();
      await until(() => calls.length > 0);
    } else if (name === "ToolCall") {
      const request = open.at(-1);
      request.end([
        { type: "tool-input-delta", id: request.toolId, delta: "pha\"}" },
        { type: "tool-input-end", id: request.toolId },
        { type: "tool-call", toolCallId: request.toolId, toolName: "lookup", input: { key: "alpha" } },
        finish("tool-calls"),
      ]);
      await until(() => calls.length > 0);
    } else if (name === "ToolEnd") {
      // Reads made from now on go through; the polls held while the tool ran
      // go only once the request after its result is out, which the view
      // then shows.
      reads.holding = false;
      const at = requests.length;
      calls[0].end();
      await until(() => requests.length > at && open.length > 0);
      reads.release();
      pinned = at;
    } else if (name === "Handoff") {
      // The deadline: the worker stops, and the same message comes back.
      reads.release();
      const before = requests.length;
      const ending = ends.held.length > 0;
      agent[durableInternals].stopAtDeadline(sessionId);
      // In `call` the turn stops before its call starts; the call's intent
      // lands as the worker lets the session go. The next delivery runs a
      // call safe to run twice again and tells the model a call with effects
      // may have partly run. A turn that is `ending` ends as its end lands,
      // and the next delivery runs the steers stored since, if any.
      records.release();
      ends.release();
      if (!ending || aim.phase === "gen") {
        await until(() => {
          gate.release();
          return (requests.length > before && open.length > 0) || calls.length > 0;
        });
      }
    } else {
      throw new Error(`no driver step for ${name}`);
    }
  }

  async function close() {
    gate.open = true;
    gate.release();
    reads.release();
    records.release();
    ends.release();
    for (const entry of [...open]) {
      try { entry.end([{ type: "error", errorText: "walk over" }]); } catch {}
    }
    for (const entry of [...calls]) entry.end();
    await Promise.race([sender.close().catch(() => {}), sleep(3000)]);
    await Promise.race([agent.close().catch(() => {}), sleep(3000)]);
    await closeAppWorlds?.();
    await rm(dir, { recursive: true, force: true });
  }

  return { perform, observe, close };
}

// ---------------------------------------------------------------------------
// Walks: seeded random paths that prefer edges no walk has covered yet.

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "../sdk/graphs", `steer-${graphName}.dot`));
const covered = new Set();
const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + targets.size, 0);
let steps = 0;
const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const actOf = (id) => graph.states.get(id).act;

for (let walk = 1; walk <= walks; walk += 1) {
  const code = await harness();
  const path = [];
  let current = new Set([graph.init]);
  try {
    for (;;) {
      const options = [];
      for (const from of current) {
        for (const to of successors(from)) {
          const act = actOf(to);
          let entry = options.find((item) => sameAct(item.act, act));
          if (!entry) options.push(entry = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) entry.fresh = true;
        }
      }
      if (options.length === 0) break;
      const fresh = options.filter((entry) => entry.fresh);
      const pool = fresh.length > 0 ? fresh : options;
      const { act } = pool[Math.floor(random() * pool.length)];
      // The state the step aims for, by an edge no walk has covered when
      // there is one: where the model lets the step end in more than one
      // state, the driver brings this one about.
      const aims = [...current].flatMap((from) => successors(from).filter((to) => sameAct(actOf(to), act)).map((to) => ({ from, to })));
      const freshAims = aims.filter(({ from, to }) => !covered.has(`${from}>${to}`));
      const aimPool = freshAims.length > 0 ? freshAims : aims;
      const aim = aimPool[Math.floor(random() * aimPool.length)];
      const label = `${act.name}${act.m === "none" ? "" : `(${act.m})`}`;
      if (verbose) console.log(`walk ${walk}: ${label}`);
      await code.perform(act, graph.states.get(aim.to));
      const seen = await code.observe();
      if (verbose) console.log(`  shows ${seen}`);
      path.push(label);
      steps += 1;
      const next = new Set();
      const allowed = new Set();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const shown = view(graph.states.get(to));
          allowed.add(shown);
          if (shown !== seen) continue;
          next.add(to);
          covered.add(`${from}>${to}`);
        }
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const shown of allowed) console.error(`  the model allows ${shown}`);
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.stack ?? error.message}`);
    process.exitCode = 1;
  } finally {
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 10 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
if (!process.exitCode) console.log(`ok steer-${graphName}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend})`);
process.exit(process.exitCode ?? 0);
