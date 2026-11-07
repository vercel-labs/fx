#!/usr/bin/env bun
// Drives real libfx, with its Zig kernel loaded through the native addon or
// WebAssembly, along paths of the TLC state graph of DurableSteer.tla, and
// checks after every step that the code is in a state the model allows.
// Then TLC checks every walk the code took again, as a trace of
// DurableSteerTrace.tla.
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
// the driver ends it, and each queue delivery waits until the driver lets it
// run, so the driver decides the interleaving. The model's Store is a steer
// stored by a second server on the same World folder, whose writes the
// running worker does not hear of, as another process's: the worker finds it
// only when it reads the log (the model's Apply), which it does on its own.
// Every read the worker makes is slowed, so a steer it would only learn of by
// reading is still unread when the driver takes the next step, which it does
// at once after a steer sent while a tool waits. The first walks start with
// two paths: a steer sent here while a tool runs, and a steer the second
// server stores followed by one sent here. After each step the driver reads
// back what the model was sent, in the newest request, which carries the
// whole conversation: a message that started a turn on the session's stream
// opens that turn, and every other message joins the turn before it, in the
// order the request holds them. With how each turn ended, from the stream,
// what the model is doing now, and what the request with the tool's result
// carried, that is the state the driver compares with the model's. The
// graphs it walks leave out the records the worker writes (MaxWrites = 0):
// with SlotOrder they change nothing the driver can see, and check.sh
// model-checks them in DurableSteer-writes.cfg.
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../../sdk/node.js";
import { createDurableAgentFactory } from "../../../sdk/durable.js";
import { local } from "../../../sdk/durable/local.mjs";
import { world } from "../../../sdk/durable/world.mjs";
import { loadGraph } from "./graph.mjs";
import { outDir, runTlc } from "./lib/tlc.ts";
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
const sdkModels = resolve(here, "../sdk");
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
const { createWorld } = await import(new URL("../../../sdk/durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const durableInternals = Symbol.for("libfx.durableInternals");
const stepTimeoutMs = 8000;
// How long the code must show the same state before the driver reads it.
const quietMs = 250;
// A running worker sees an input this process stores at once, and one the
// other server stores when it next reads the log, which a local() World has
// it do every 250 ms; the driver waits that out after an input before it
// reads the code.
const inputMs = 400;
// What the worker does on its own: read the log.
const autoActs = new Set(["Apply"]);
// How much longer each of the worker's log reads takes.
const readDelayMs = 100;
// The paths the first walks start with: a steer sent here while a tool runs,
// which a worker that hears of it only by reading misses; and a steer the
// other server stores followed by one sent here, which waits for the read
// so the turn takes both in the order they were stored.
const scripts = [
  ["Send(p)", "Start", "ToolArgs", "ToolCall", "Send(s1)", "ToolEnd"],
  ["Send(p)", "Start", "ToolArgs", "ToolCall", "Store(s1)", "Send(s2)", "ToolEnd"],
];

// What each message says, so a request shows which messages it carries.
const textOf = (m) => (m === "p" ? "prompt p" : `steer ${m}`);
const messageIn = (text) => /\b(?:prompt (p)|steer (s\d+))\b/.exec(text)?.slice(1).find(Boolean) ?? null;
const steering = (text) => text.startsWith("<user_steering>");

// ---------------------------------------------------------------------------
// The state graph TLC wrote.

const sorted = (items) => [...items].sort();
// What the driver compares: what the model was sent, in order, how each turn
// ended, what the model is doing now, and what the request with the tool's
// result carried for the running turn.
const shown = (state) => {
  const turns = state.turns.filter((turn) => turn.state !== "waiting");
  const placed = new Set(turns.flatMap((turn) => turn.ctx));
  return {
    turns: turns.map((turn) => ({ owner: turn.owner, state: turn.state, ctx: turn.ctx })),
    phase: state.phase,
    twice: sorted(state.dup.filter((m) => placed.has(m))),
    atTool: state.atTool,
  };
};
const view = (state) => JSON.stringify(shown(state));
const sameAct = (a, b) => a.name === b.name && a.m === b.m;
const labelOf = (act) => `${act.name}${act.m === "none" ? "" : `(${act.m})`}`;

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
const bound = (target, key) => {
  const value = Reflect.get(target, key);
  return typeof value === "function" ? value.bind(target) : value;
};

// The queue as the driver runs it. Each delivery waits until the driver lets
// it run, as one does while the platform has not delivered it yet; every
// input reaches the log when it is sent, before its delivery, so only when a
// worker starts waits. A message the code asks to have delivered again later,
// as a backstop, is not, so nothing runs that the driver did not start. Each
// listing of the World's events, which every read of the log makes, takes
// readDelayMs longer.
function gatedDeliveries(durability, gate) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      const events = new Proxy(world.events, {
        get(target, key) {
          if (key !== "list") return bound(target, key);
          return async (...listArgs) => {
            await sleep(readDelayMs);
            return target.list(...listArgs);
          };
        },
      });
      return new Proxy(world, {
        get(target, key) {
          if (key === "events") return events;
          if (key !== "createQueueHandler") return bound(target, key);
          return (prefix, handler) => target.createQueueHandler(prefix, async (...handlerArgs) => {
            await gate.wait();
            const result = await handler(...handlerArgs);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

// Another server on the same World folder: it stores steers and queues
// nothing, and the running worker does not hear of its writes.
async function otherServer(dir) {
  const instance = createWorld({ dataDir: dir, recoverActiveRuns: false });
  await instance.start?.();
  let queued = 0;
  const quiet = new Proxy(instance, {
    get(target, key) {
      if (key === "queue") return async () => ({ messageId: `msg_other_${++queued}` });
      return bound(target, key);
    },
  });
  const createAgent = createDurableAgentFactory({
    name: "createOtherServer",
    defaultDurability: async () => { throw new Error("the driver passes a durability"); },
    harness: () => ({ open() { throw new Error("this server only stores steers"); } }),
  });
  const agent = createAgent({ durability: world(quiet, { name: "other", store: "other" }) });
  return {
    steer: (sessionId, text, messageId) => agent.session(sessionId).steer(text, { messageId }),
    async close() {
      await agent.close().catch(() => {});
      await instance.close?.().catch(() => {});
    },
  };
}

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-steer-model-"));
  // Every model request so far, and the open ones.
  const requests = [];
  const open = [];
  const calls = [];
  // Where in `requests` each tool result's request is.
  const toolEnds = [];
  let toolCalls = 0;
  let sessionId = null;
  let session = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  // Deliveries the driver has not let run yet.
  const gate = {
    held: [],
    open: false,
    wait() { return gate.open ? Promise.resolve() : new Promise((go) => gate.held.push(go)); },
    release() { for (const go of gate.held.splice(0)) go(); },
  };
  const stored = durabilityKind === "world" ? await appWorldAt(dir) : local({ dir });
  const durability = gatedDeliveries(stored, gate);
  const other = await otherServer(dir);
  const agent = createFxAgent({
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
      execute: (toolInput, { signal }) => new Promise((resolveCall, rejectCall) => {
        const entry = { aborted: false, end: () => { remove(calls, entry); resolveCall(`value of ${toolInput.key}`); } };
        calls.push(entry);
        signal?.addEventListener("abort", () => { entry.aborted = true; remove(calls, entry); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
      }),
    }],
    durability,
  });

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
    // The turns a request carries: a message that started a turn on the
    // stream opens it, and every other message joins the turn before it, in
    // the order the request holds them. A steer that joined a turn reaches
    // the model as a live update, a resumed turn's too, but the stream, not
    // the text, says who owns a turn.
    const turnsIn = (users) => {
      const turns = [];
      for (const text of users) {
        const m = messageIn(text);
        if (!m) continue;
        if (stateOf.has(m) && !steering(text) && !turns.some((turn) => turn.owner === m)) turns.push({ owner: m, ctx: [m] });
        else if (turns.length > 0 && !turns.at(-1).ctx.includes(m)) turns.at(-1).ctx.push(m);
      }
      return turns;
    };
    const turns = turnsIn(requests.at(-1)?.users ?? []);
    const counts = new Map();
    for (const text of requests.at(-1)?.users ?? []) {
      const m = messageIn(text);
      if (m) counts.set(m, (counts.get(m) ?? 0) + 1);
    }
    const phase = calls.length > 0 ? "tool" : open.length > 0 ? open.at(-1).phase : "idle";
    // The running turn as the request with the last tool result carried it.
    const atTool = toolEnds.length === 0 ? [] : turnsIn(requests[toolEnds.at(-1)]?.users ?? []).at(-1)?.ctx ?? [];
    return JSON.stringify({
      turns: turns.map((turn) => ({ owner: turn.owner, state: stateOf.get(turn.owner) ?? "running", ctx: turn.ctx })),
      phase,
      twice: sorted([...counts].filter(([, count]) => count > 1).map(([m]) => m)),
      atTool,
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

  // What the user sends: a message, the same steer again, or a cancel, from
  // this process, or a steer the other server stores.
  async function performInput({ name, m }) {
    if (name === "Cancel") {
      await session.cancel();
    } else if (name === "Store") {
      await other.steer(sessionId, textOf(m), m);
    } else if (m === "p") {
      session = agent.session();
      const turn = session.prompt(textOf("p"), { messageId: "p" });
      void turn.result.catch(() => {});
      sessionId = (await turn.accepted).sessionId;
      await until(() => gate.held.length > 0);
    } else {
      // The steer's own id, which libfx before identities ignores.
      await session.steer(textOf(m), { messageId: m });
    }
  }

  // One step of the model, done to the code. With `next`, the driver takes
  // its next step at once.
  async function perform({ name, m }, { next = false } = {}) {
    if (name === "Send" || name === "Store" || name === "Retry" || name === "Cancel") {
      await performInput({ name, m });
      if (!next) await sleep(inputMs);
      return;
    }
    if (name === "Start") {
      gate.release();
      await until(() => open.length > 0);
    } else if (name === "ModelText") {
      open.at(-1).end([{ type: "text-delta", id: "reply", delta: "done" }, finish("stop")]);
    } else if (name === "ToolArgs") {
      const request = open.at(-1);
      toolCalls += 1;
      request.toolId = `call-${toolCalls}`;
      request.phase = "args";
      request.send([
        { type: "tool-input-start", id: request.toolId, toolName: "lookup" },
        { type: "tool-input-delta", id: request.toolId, delta: "{\"key\":\"al" },
      ]);
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
      // The next request is the one with the tool's result.
      toolEnds.push(requests.length);
      calls[0].end();
      await until(() => open.length > 0);
    } else if (name === "Handoff") {
      // The deadline: the worker stops, and the same message comes back.
      const before = requests.length;
      agent[durableInternals].stopAtDeadline(sessionId);
      await until(() => {
        gate.release();
        return requests.length > before && open.length > 0;
      });
    } else {
      throw new Error(`no driver step for ${name}`);
    }
  }

  async function close() {
    gate.open = true;
    gate.release();
    for (const entry of [...open]) {
      try { entry.end([{ type: "error", errorText: "walk over" }]); } catch {}
    }
    for (const entry of [...calls]) entry.end();
    await Promise.race([agent.close().catch(() => {}), sleep(3000)]);
    await other.close();
    await closeAppWorlds?.();
    await rm(dir, { recursive: true, force: true });
  }

  return { perform, observe, close, served: () => requests.length };
}

// ---------------------------------------------------------------------------
// TLC checks each walk the code took as a trace of DurableSteerTrace.tla.

const tla = (value) => {
  if (Array.isArray(value)) return `<<${value.map(tla).join(", ")}>>`;
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  return `[${Object.entries(value).map(([key, item]) => `${key} |-> ${tla(item)}`).join(", ")}]`;
};
const shownTla = (seen) => `[turns |-> ${tla(seen.turns)}, phase |-> ${tla(seen.phase)}, twice |-> {${seen.twice.map(tla).join(", ")}}, atTool |-> ${tla(seen.atTool)}]`;
const unseen = { turns: [], phase: "idle", twice: [], atTool: [] };
const stepTla = (step) => `[name |-> ${tla(step.name)}, m |-> ${tla(step.m)}, seen |-> ${tla(step.seen !== null)}, view |-> ${shownTla(step.seen ?? unseen)}]`;

async function checkTraces(recorded) {
  const dir = outDir(`steer-${graphName}`);
  await writeFile(join(dir, "DurableSteerObserved.tla"), [
    "------------------------- MODULE DurableSteerObserved -------------------------",
    "\\* Generated by tests/tla/drivers/drive-steer.mjs: the walks it took through libfx.",
    `Observed == <<${recorded.map((steps) => `<<${steps.map(stepTla).join(",\n    ")}>>`).join(",\n  ")}>>`,
    "=============================================================================",
    "",
  ].join("\n"));
  // The constants of the graph the walks took.
  const cfg = await readFile(join(sdkModels, `DurableSteer-${graphName}.cfg`), "utf8");
  const constants = cfg.slice(0, cfg.indexOf("SPECIFICATION"));
  await writeFile(join(dir, "trace.cfg"), `${constants}SPECIFICATION TraceSpec\nINVARIANT NotAllMatched\n`);
  const run = await runTlc(dir, "DurableSteerTrace.tla", "trace.cfg", ["DurableSteer.tla", "DurableSteerTrace.tla"], sdkModels, ["-deadlock"]);
  return { accepted: run.violated === "NotAllMatched", dir, run };
}

// ---------------------------------------------------------------------------
// Walks: seeded random paths that prefer edges no walk has covered yet.

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(sdkModels, "graphs", `steer-${graphName}.dot`));
const covered = new Set();
const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + targets.size, 0);
let steps = 0;
let served = 0;
const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const actOf = (id) => graph.states.get(id).act;
// Each state the worker may have reached on its own from `ids`, with the edges.
const mayApply = (ids, edges = null) => {
  const all = new Set(ids);
  const queue = [...ids];
  while (queue.length > 0) {
    const from = queue.shift();
    for (const to of successors(from).filter((id) => autoActs.has(actOf(id).name))) {
      edges?.add(`${from}>${to}`);
      if (!all.has(to)) { all.add(to); queue.push(to); }
    }
  }
  return all;
};
// The states the worker settles in once it has read the log.
const settled = (ids, edges) => [...mayApply(ids, edges)].filter((id) => !successors(id).some((to) => autoActs.has(actOf(to).name)));
// Whether the turn waits on a tool's call or result.
const onTool = (ids) => [...ids].some((id) => ["args", "tool"].includes(graph.states.get(id).phase));
const isSteer = (entry) => ["Send", "Store"].includes(entry.act.name) && entry.act.m !== "p";

// Every walk the code took, for TLC: each step and what the code showed.
const recorded = [];
for (let walk = 1; walk <= walks; walk += 1) {
  const code = await harness();
  const path = [];
  const taken = [];
  recorded.push(taken);
  const script = scripts[walk - 1] ?? [];
  let current = new Set([graph.init]);
  // Whether the last step stored a steer the worker may not have read.
  let unread = false;
  try {
    for (;;) {
      // A step the code took without being read since may have let the
      // worker read the log first.
      current = mayApply(current);
      const options = [];
      for (const from of current) {
        for (const to of successors(from)) {
          const act = actOf(to);
          if (autoActs.has(act.name)) continue;
          let entry = options.find((item) => sameAct(item.act, act));
          if (!entry) options.push(entry = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) entry.fresh = true;
        }
      }
      if (options.length === 0) break;
      const scripted = options.find((entry) => labelOf(entry.act) === script[path.length]);
      const fresh = options.filter((entry) => entry.fresh);
      // While a tool runs, a steer is often sent, and after one the tool
      // mostly returns next: that is where a steer the worker has not read
      // can miss the request with the tool's result. Outside the tool, a
      // running turn's steers are often held back for it.
      const toolEnd = unread ? options.find((entry) => entry.act.name === "ToolEnd") : undefined;
      const phaseNow = graph.states.get([...current][0]).phase;
      const steerNow = phaseNow === "tool" && !unread ? options.filter(isSteer) : [];
      const held = ["gen", "args"].includes(phaseNow) && random() < 0.6 ? options.filter((entry) => !isSteer(entry)) : [];
      const base = fresh.length > 0 ? fresh : options;
      const calm = base.filter((entry) => !isSteer(entry));
      const pool = scripted ? [scripted]
        : toolEnd && random() < 0.75 ? [toolEnd]
        : steerNow.length > 0 && random() < 0.8 ? steerNow
        : held.length > 0 ? (calm.length > 0 ? calm : held)
        : base;
      const { act } = pool[Math.floor(random() * pool.length)];
      const label = labelOf(act);
      if (verbose) console.log(`walk ${walk}: ${label}`);
      // A steer stored while the turn waits on a tool is not read now: the
      // next step comes at once, before the worker can read it.
      const stored = isSteer({ act }) && onTool(current);
      unread = stored;
      await code.perform(act, { next: stored });
      path.push(label);
      steps += 1;
      if (stored) {
        taken.push({ name: act.name, m: act.m, seen: null });
        const next = new Set();
        for (const from of current) {
          for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
            next.add(to);
            covered.add(`${from}>${to}`);
          }
        }
        current = next;
        continue;
      }
      const seen = await code.observe();
      if (verbose) console.log(`  shows ${seen}`);
      taken.push({ name: act.name, m: act.m, seen: JSON.parse(seen) });
      const next = new Set();
      const allowed = new Set();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const edges = new Set([`${from}>${to}`]);
          for (const end of settled([to], edges)) {
            const expected = view(graph.states.get(end));
            allowed.add(expected);
            if (expected !== seen) continue;
            next.add(end);
            for (const edge of edges) covered.add(edge);
          }
        }
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const expected of allowed) console.error(`  the model allows ${expected}`);
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.stack ?? error.message}`);
    process.exitCode = 1;
  } finally {
    served += code.served();
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 10 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
const traced = await checkTraces(recorded);
if (traced.accepted) console.log(`TLC accepted all ${recorded.length} walks as traces of DurableSteerTrace.tla (${traced.run.distinctStates} states, ${traced.dir})`);
else {
  console.error(`FAIL TLC rejected the walks as traces of DurableSteerTrace.tla; see ${traced.dir}/tlc.log`);
  process.exitCode = 1;
}
if (!process.exitCode) console.log(`ok steer-${graphName}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend}, ${durabilityKind}); the fake gateway served ${served} model requests`);
process.exit(process.exitCode ?? 0);
