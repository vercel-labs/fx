#!/usr/bin/env bun
// Drives real libfx, with its Zig kernel loaded through the native addon, along
// paths of the TLC state graph of ResumedSteer.tla, and checks after every step
// that the code shows what the model allows: which steers the journal accepted
// and placed, how many lines the session's stream holds for each, and whether
// the turn ended.
//
//   bun tests/tla/drivers/drive-resumed-steer.mjs [--walks N] [--seed S] [--verbose]
//
// `tests/tla/sdk/check-resumed-steer.sh` model-checks the spec and writes
// graphs/resumed-steer.dot. Only the native core is driven: the WebAssembly
// core takes steers from its host at a boundary, so a steer there is still a
// stored input when a run ends, and the resumed turn shows it like any other.
//
// Each walk runs a session on a fresh local() World directory. The session's
// worker is a child process of this one, which this process kills with
// SIGKILL for a crash. The child answers the model's requests itself, holds a
// lookup call until the driver ends it, and holds each queue delivery until
// the driver lets it run, so the driver decides the interleaving:
//
//   Send(s)     a steer while the call runs, read back from the log once the turn took it
//   ToolEnd     the call returns; the turn takes the steers, places them and answers
//   TakeCrash   the same, with the log's writes held after the turn showed the steers:
//               the child is killed before the progress that places them lands
//   Handoff     the worker stops as its deadline would
//   Crash       SIGKILL while the call runs
//   Resume      the same message comes back (after a hand-off) or a new child
//               resumes the session (after a crash); it runs the call again
//
// Publish and Reply are the code's own steps. The graph has no cancels
// (`ResumedSteer-drive.cfg`); sdk/tests/test-durable.mjs covers one. The code is compared with the model through
// `view`, and each ToolEnd also checks that the model was sent every steer the
// journal placed, once.
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../../sdk/node.js";
import { local } from "../../../sdk/durable/local.mjs";
import { holdWrites } from "../../../sdk/tests/hold-writes.mjs";
import { loadGraph, walkGraph } from "./graph.mjs";

const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const durableInternals = Symbol.for("libfx.durableInternals");
const steerIds = ["s1", "s2"];
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));
const until = async (check, what, ms = 8000) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) throw new Error(`timed out waiting for ${what}`);
    await sleep(5);
  }
};

// ---------------------------------------------------------------------------
// What both sides show: the journal's record of each steer, the lines the
// stream holds for it, and whether the turn ended.

const viewOf = (jr, shown, over) => ({
  jr: Object.fromEntries(steerIds.map((id) => [id, jr[id]])),
  shown: Object.fromEntries(steerIds.map((id) => [id, shown[id]])),
  over,
});

// The log's marks say which steers the turn accepted and which a progress placed.
function journalOf(entries) {
  const jr = Object.fromEntries(steerIds.map((id) => [id, "none"]));
  for (const { entry } of entries) {
    for (const mark of entry?.marks ?? []) {
      if (typeof mark.accepted === "string" && jr[mark.accepted] === "none") jr[mark.accepted] = "accepted";
      if (typeof mark.placed === "string" && mark.placed in jr) jr[mark.placed] = "placed";
    }
  }
  return jr;
}

// The session's stream as a reader shows it: its lines until it is quiet.
async function streamLines(agent, sessionId) {
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

async function readView(agent, sessionId) {
  const log = await agent[durableInternals].openLog(sessionId);
  const lines = await streamLines(agent, sessionId);
  const shown = Object.fromEntries(steerIds.map((id) => [id, lines.filter((line) => line.type === "user_message" && line.id === id).length]));
  return { view: viewOf(journalOf(await log.read()), shown, lines.some((line) => line.type === "turn_end")), lines };
}

// ---------------------------------------------------------------------------
// The child: one worker process.

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const encoder = new TextEncoder();

// The queue as the child runs it. A delivery waits until the driver lets it
// run, and a message the code asks to have delivered again later, as a
// backstop, is dropped, so nothing runs that the driver did not start.
function gatedDeliveries(durability, gate) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
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

async function runChild(dir, role, knownSession) {
  const requests = [];
  const calls = [];
  const queued = new Set();
  const hold = { armed: false };
  const gate = {
    held: [],
    wait() { return new Promise((go) => gate.held.push(go)); },
    release() { for (const go of gate.held.splice(0)) go(); },
  };
  // Once armed, every write of the journal's records is held: the call's
  // result and the progress that places the steers stay out of the log.
  const [durability] = holdWrites(gatedDeliveries(local({ dir }), gate), (entry) => hold.armed && entry.k === "record");
  const agent = createFxAgent({
    backend: "native",
    nativeAddon: addon,
    apiKey: "model-key-not-real",
    model: "model/test",
    async fetch(input, init) {
      const request = input instanceof Request ? input : new Request(input, init);
      if (request.method === "GET") return Response.json({ object: "list", data: [{ id: "model/test", type: "language" }] });
      const prompt = JSON.parse(await request.text()).prompt;
      const users = prompt.filter((message) => message.role === "user").map((message) => (typeof message.content === "string"
        ? message.content
        : message.content.filter((part) => part.type === "text").map((part) => part.text).join("")));
      requests.push(users);
      const answered = prompt.some((message) => Array.isArray(message.content) && message.content.some((part) => part.type === "tool-result"));
      const frames = answered
        ? [{ type: "text-delta", id: "reply", delta: "done" }, finish("stop")]
        : [{ type: "tool-call", toolCallId: "call-1", toolName: "lookup", input: { key: "alpha" } }, finish("tool-calls")];
      const body = `${frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("")}data: [DONE]\n\n`;
      return new Response(encoder.encode(body), { headers: { "content-type": "text/event-stream" } });
    },
    tools: [{
      name: "lookup",
      description: "Looks up a key",
      idempotent: true,
      inputSchema: { type: "object", properties: { key: { type: "string" } } },
      execute: (toolInput, { signal }) => new Promise((resolveCall, rejectCall) => {
        const entry = { end: () => { calls.splice(calls.indexOf(entry), 1); resolveCall(`value of ${toolInput.key}`); } };
        calls.push(entry);
        signal?.addEventListener("abort", () => { const at = calls.indexOf(entry); if (at >= 0) calls.splice(at, 1); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
      }),
    }],
    durability,
  });
  let sessionId = knownSession || null;
  let session = sessionId ? agent.session(sessionId) : null;
  const count = async (...types) => (await streamLines(agent, sessionId)).filter((line) => types.includes(line.type)).length;

  const commands = {
    async start() {
      session = agent.session();
      const turn = session.prompt("use lookup", { messageId: "p" });
      void turn.result.catch(() => {});
      sessionId = (await turn.accepted).sessionId;
      await until(() => gate.held.length > 0, "the first delivery");
      gate.release();
      await until(() => calls.length > 0, "the call to start");
      // The model starts with its turn open in the log, and the call's intent
      // in it: a worker killed before either landed leaves a turn the resume
      // starts over instead of continuing, which waits far longer.
      const log = await agent[durableInternals].openLog(sessionId);
      const marked = async (wanted) => (await log.read()).some(({ entry }) => entry?.marks?.some(wanted));
      await until(() => marked((mark) => typeof mark.start === "string"), "the turn to open in the log");
      await until(() => marked((mark) => typeof mark.step === "string" && mark.step.endsWith(":uncertain")), "the call's intent to land");
      return { sessionId };
    },
    async steer({ steer }) {
      await session.steer(`steer ${steer}`, { messageId: steer });
      const log = await agent[durableInternals].openLog(sessionId);
      await until(async () => journalOf(await log.read())[steer] !== "none", "the turn to take the steer");
      queued.add(steer);
      return {};
    },
    async toolEnd() {
      calls[0].end();
      await until(async () => (await count("turn_end")) > 0, "the turn to end");
      return { users: requests.at(-1) };
    },
    async hold() {
      hold.armed = true;
      return {};
    },
    // The call returns with the log's writes held: the turn shows the steers it
    // takes, and its progress stays out of the log.
    async toolEndHeld() {
      calls[0].end();
      await until(async () => {
        const lines = await streamLines(agent, sessionId);
        return [...queued].every((id) => lines.some((line) => line.type === "user_message" && line.id === id));
      }, "the turn to show the steers it took");
      return {};
    },
    async handoff() {
      const yielded = await count("turn_yield");
      agent[durableInternals].stopAtDeadline(sessionId);
      await until(async () => (await count("turn_yield")) > yielded, "the turn to hand off");
      queued.clear();
      return {};
    },
    async resume({ fresh }) {
      // A crash before the turn's first progress landed leaves nothing to
      // resume: the prompt starts again, and the stream shows a start.
      const resumes = await count("turn_resume", "turn_start");
      let resumed = "";
      if (fresh) {
        const turn = session.resume();
        turn.result.then((result) => { resumed = `resumed turn ended ${result.stopReason}`; }, (error) => { resumed = `resume failed: ${error?.message}`; });
      }
      // The delivery reaches the gate after a moment; each pass lets it through.
      await until(async () => {
        gate.release();
        return calls.length > 0 && (await count("turn_resume", "turn_start")) > resumes;
      }, "the call to run again").catch(async (error) => {
        const types = (await streamLines(agent, sessionId)).map((line) => line.type).filter((type) => !type.endsWith("_delta"));
        const lease = await agent[durableInternals].lastLease(sessionId).catch(() => null);
        throw new Error(`${error.message}; stream: ${types.join(" ")}; model requests: ${requests.length}; calls: ${calls.length}; held deliveries: ${gate.held.length}; lease: ${JSON.stringify(lease)}; stands: ${await agent[durableInternals].leaseStands(sessionId).catch(() => "?")}; ${resumed}`);
      });
      return {};
    },
    async quit() {
      gate.release();
      await Promise.race([agent.close().catch(() => {}), sleep(2000)]);
      process.exit(0);
    },
  };

  const reply = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
  createInterface({ input: process.stdin }).on("line", async (line) => {
    const message = JSON.parse(line);
    try {
      reply({ id: message.id, ok: true, ...(await commands[message.cmd](message)) });
    } catch (error) {
      reply({ id: message.id, ok: false, error: String(error?.stack ?? error) });
    }
  });
  await new Promise(() => {});
}

// ---------------------------------------------------------------------------
// This process: the driver.

async function driver() {
  const args = process.argv.slice(2);
  const option = (name, fallback) => {
    const index = args.indexOf(`--${name}`);
    return index >= 0 ? args[index + 1] : fallback;
  };
  const walks = Number(option("walks", 20));
  const verbose = args.includes("--verbose");
  let seed = Number(option("seed", 1));
  const random = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed / 2147483648;
  };
  const quietMs = 250;
  const settleMs = 10_000;

  // Each fx process the driver starts has its own profile and talks only to
  // the child's local model.
  const childEnv = (home) => ({
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: home,
    FX_HOME: home,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
  });

  async function open(walk) {
    const dir = await mkdtemp(join(tmpdir(), "libfx-resumed-steer-"));
    const problems = [];
    const kids = [];
    let kid = null;
    let sessionId = null;
    // The observer reads the session's log and stream, and runs nothing.
    const observer = createFxAgent({
      backend: "native",
      nativeAddon: addon,
      apiKey: "model-key-not-real",
      model: "model/test",
      fetch: () => { throw new Error("the observer never asks the model"); },
      durability: local({ dir }),
    });

    function spawnKid(role) {
      const proc = spawn(process.execPath, [fileURLToPath(import.meta.url), "--child", dir, role, sessionId ?? ""], {
        stdio: ["pipe", "pipe", "pipe"],
        env: childEnv(dir),
      });
      const waiting = new Map();
      let stderr = "";
      let exited = null;
      let killed = false;
      let next = 1;
      proc.stderr.on("data", (chunk) => { stderr += chunk; });
      createInterface({ input: proc.stdout }).on("line", (line) => {
        let message;
        try { message = JSON.parse(line); } catch { return; }
        waiting.get(message.id)?.(message);
        waiting.delete(message.id);
      });
      const done = new Promise((resolveExit) => proc.once("exit", (code, signal) => {
        exited = { code, signal };
        if (!killed) problems.push(`a worker process exited on its own: ${JSON.stringify(exited)} ${stderr.slice(-400)}`);
        for (const answer of waiting.values()) answer({ ok: false, error: `the worker process exited: ${JSON.stringify(exited)} ${stderr.slice(-400)}` });
        resolveExit(exited);
      }));
      const entry = {
        cmd(command, extra = {}) {
          const id = next++;
          return new Promise((resolveCommand, rejectCommand) => {
            const timer = setTimeout(() => rejectCommand(new Error(`${command} timed out; ${stderr.slice(-400)}`)), 20_000);
            waiting.set(id, (message) => {
              clearTimeout(timer);
              if (message.ok) resolveCommand(message);
              else rejectCommand(new Error(`${command}: ${message.error}`));
            });
            proc.stdin.write(`${JSON.stringify({ id, cmd: command, ...extra })}\n`);
          });
        },
        async kill() {
          killed = true;
          proc.kill("SIGKILL");
          await done;
        },
        async quit() {
          killed = true;
          proc.stdin.write(`${JSON.stringify({ id: 0, cmd: "quit" })}\n`);
          await Promise.race([done, sleep(3000)]);
          if (!exited) proc.kill("SIGKILL");
        },
        alive: () => exited === null,
      };
      kids.push(entry);
      return entry;
    }

    kid = spawnKid("fresh");
    sessionId = (await kid.cmd("start")).sessionId;

    async function perform({ name, m }) {
      if (name === "Send") {
        await kid.cmd("steer", { steer: m });
      } else if (name === "ToolEnd") {
        const { users } = await kid.cmd("toolEnd");
        // The model was sent every steer the journal placed, once.
        const { view } = await readView(observer, sessionId);
        const sent = users.flatMap((text) => [...text.matchAll(/steer (s\d+)/g)].map((found) => found[1]));
        const placed = steerIds.filter((id) => view.jr[id] === "placed");
        if (JSON.stringify([...sent].sort()) !== JSON.stringify(placed)) {
          problems.push(`the model's last request held steers [${sent}], the journal placed [${placed}]`);
        }
      } else if (name === "TakeCrash") {
        await kid.cmd("hold");
        await kid.cmd("toolEndHeld");
        await kid.kill();
        kid = null;
      } else if (name === "Handoff") {
        await kid.cmd("handoff");
      } else if (name === "Crash") {
        // The worker's last writes land first: a kill in the middle of one
        // leaves a torn file in the World, which is not what this model is about.
        await sleep(500);
        await kid.kill();
        kid = null;
      } else if (name === "Resume") {
        if (kid) {
          await kid.cmd("resume", { fresh: false });
        } else {
          kid = spawnKid("resume");
          await kid.cmd("resume", { fresh: true });
        }
      } else {
        throw new Error(`no driver step for ${name}`);
      }
    }

    // The code has settled when it shows the same state for quietMs.
    async function settle() {
      let seen = JSON.stringify((await readView(observer, sessionId)).view);
      const started = Date.now();
      for (;;) {
        await sleep(quietMs);
        const again = JSON.stringify((await readView(observer, sessionId)).view);
        if (again === seen) break;
        seen = again;
        if (Date.now() - started > settleMs) break;
      }
      return JSON.parse(seen);
    }

    async function close() {
      for (const entry of kids) if (entry.alive()) await entry.quit().catch(() => {});
      await Promise.race([observer.close().catch(() => {}), sleep(2000)]);
      await rm(dir, { recursive: true, force: true });
    }

    return { perform, settle, close, problems };
  }

  const graph = await loadGraph(resolve(here, "../sdk/graphs/resumed-steer.dot"));
  const view = (state) => JSON.stringify(viewOf(state.jr, state.shown, state.run === "done"));
  const { steps, covered, totalEdges } = await walkGraph({
    graph,
    walks,
    random,
    autoActs: new Set(["Publish", "Reply"]),
    nameOf: (act) => act.name,
    sameAct: (a, b) => a.name === b.name && a.m === b.m,
    label: (act) => `${act.name}${act.m === "none" ? "" : `(${act.m})`}`,
    view,
    open,
    verbose,
  });
  if (!process.exitCode) console.log(`ok resumed-steer: ${walks} walks, ${steps} steps matched the model; ${covered} of ${totalEdges} edges covered (native)`);
  process.exit(process.exitCode ?? 0);
}

if (process.argv[2] === "--child") await runChild(process.argv[3], process.argv[4], process.argv[5]);
else await driver();
