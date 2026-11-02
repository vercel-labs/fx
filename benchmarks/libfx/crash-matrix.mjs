#!/usr/bin/env node
// Crash matrix: kill a libfx process at every step of a turn and check what
// the next process does.
//
// For each backend and workload, a worker child runs a committed setup turn,
// saves a checkpoint, then runs the crash turn one step at a time: it prints
// each step (prompt sent, each turn event, before and after each tool's side
// effect) and waits for an ack on stdin. The parent kills it with SIGKILL at
// step k instead of acking, then starts a restorer child. In "today" mode
// the restorer does what a host can do without a journal: restore the last
// checkpoint and send the stored prompt again. Side effects are counted from
// a file, and each cell is checked by durable.mjs checkCrashCell. Failures
// in "today" mode are recorded, not fatal, unless --require-clean is set.
//
// In "journal" mode the worker persists the session to a JSONL file through
// `persistence`, with a step before and after each record lands, and saves
// no checkpoint. The restorer opens the session from that file alone. It
// calls `resume()` when the journal holds the crashed turn open, does nothing
// when the turn was committed, and sends the prompt again only when no trace
// of the turn reached the journal. Then it reopens the file once more. Two
// more invariants apply: JournalFolds (every reopen succeeds) and
// StartsWithDurableIntent (checked as each tool call starts).
//
// "world" mode is journal mode with the session in a world-local World,
// through the persistence store in sdk/tests/world-persistence.mjs
// (--world-root holds @workflow/world-local).
//
// --race (journal or world mode) holds the worker at step k instead of
// killing it, runs the restorer while it waits, then releases it: a second
// process takes the session over while the first is still alive. Two more
// invariants apply: FencedNeverWrites (the released worker leaves the
// session as the restorer left it) and SendRunsOnce over both processes.
//
// --inputs (journal or world mode) steers the crash turn and queues a
// follow-up when its first tool runs, each acknowledgement a step of its
// own. AckedAreDurable: an acknowledged steer or follow-up reaches the model
// after the restore; PlacedOnce: neither reaches it twice.
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxEngine, FxFencedError } from "../../sdk/node.js";
import { worldPersistence } from "../../sdk/tests/world-persistence.mjs";
import { checkCrashCell, durableWorkloads, journalRecord, promptDirectives, recordEvents, toolResultIds } from "./durable.mjs";
import { agentOptions, hostTools, listOption, parseArgs, scriptedFetch } from "./durable-host.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const options = parseArgs(process.argv.slice(2), {
  child: "",
  backend: "native",
  backends: "native,wasm",
  workload: "",
  workloads: "no-tool,one-safe,one-send,list-then-read,write-then-read",
  dir: "",
  mode: "today",
  // The Worlds libfx bundles, installed by `npm ci --prefix sdk/durable`.
  "world-root": fileURLToPath(new URL("../../sdk/durable/", import.meta.url)),
  race: false,
  inputs: false,
  "require-clean": false,
  "timeout-ms": "20000",
});
if (!["today", "journal", "world"].includes(options.mode)) throw new Error("--mode must be today, journal or world");
const worldMode = options.mode === "world";
const journaled = options.mode !== "today";
if (options.race && !journaled) throw new Error("--race needs --mode journal or world");
if (options.inputs && !journaled) throw new Error("--inputs needs --mode journal or world");
const setupTurns = 1;
const steerText = "steer=keep";
const followUpText = "workload=no-tool follow";

// How often the steer and the follow-up reached the model in `prompt`.
function inputCounts(prompt) {
  const users = prompt.filter((message) => message.role === "user").map(textOf);
  return {
    steers: users.filter((text) => text.includes(steerText)).length,
    followUps: users.filter((text) => text.includes(followUpText)).length,
  };
}

// Runs every turn `resume()` hands back: the open turn, then held follow-ups.
async function resumeAll(agent) {
  let first = null;
  for (let turn = agent.resume(); turn; turn = agent.resume()) {
    for await (const _ of turn) {}
    const result = await turn.result;
    first ??= result;
  }
  return first;
}

const stepsFor = (prompt) => durableWorkloads[promptDirectives(prompt).workload] ?? durableWorkloads["no-tool"];
const textOf = (message) => (Array.isArray(message.content) ? message.content.filter((part) => part.type === "text").map((part) => part.text).join("") : String(message.content ?? ""));

const createWorld = worldMode && options.child
  ? (await import(pathToFileURL(join(options["world-root"], "node_modules/@workflow/world-local/dist/index.js")).href)).createWorld
  : null;

if (options.child === "worker") await worker();
else if (options.child === "restorer") await restorer();
else if (options.child === "inspect") await inspect();
else await parent();

// Children: the effects live here (files, stdout, the agent).

function intentStored(path, callId) {
  if (!existsSync(path) || !callId) return false;
  return readFileSync(path, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
    .some((event) => event.type === "tool_intent" && event.data.some((call) => call.id === callId));
}

// A persistence store in a JSONL file, one event per line, so a kill leaves
// whole lines. A record's cursor is the last seq it holds, and an append whose
// `expected` cursor is not the file's last seq is fenced, so a process whose
// session was taken over cannot interleave with the new one. `step` brackets
// the write when the worker is stepping.
// Declarations, not consts: the child roles run before this point.
function readEvents(path) {
  const text = existsSync(path) ? readFileSync(path, "utf8") : "";
  return text.split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function fileStore(path, step = null) {
  const head = () => {
    const last = readEvents(path).at(-1);
    return last ? String(last.seq) : null;
  };
  return {
    async load() {
      const events = readEvents(path);
      return { journal: events.length ? [{ cursor: String(events.at(-1).seq), data: journalRecord(events) }] : [] };
    },
    async append({ expected, data }) {
      const batch = recordEvents(data);
      if (step) await step(`journal_before:${batch.map((event) => event.type).join("+")}`);
      if (expected !== head()) throw new FxFencedError(`expected cursor ${expected}, head ${head()}`);
      appendFileSync(path, batch.map((event) => `${JSON.stringify(event)}\n`).join(""));
      if (step) await step("journal_after");
      return { cursor: String(batch.at(-1).seq) };
    },
  };
}

function openWorld() {
  return createWorld({ dataDir: join(options.dir, "world"), recoverActiveRuns: false });
}

// world-local's queue teardown calls undici's Agent.close(), which Bun's
// built-in undici lacks; only that known failure is skipped.
async function closeWorld(world) {
  try {
    await world.close?.();
  } catch (error) {
    if (!(process.versions.bun && error instanceof TypeError && error.message.includes("httpAgent?.close"))) throw error;
  }
}

// The events in one of the World store's record steps, or null.
function recordStepEvents(request) {
  if (request?.eventData?.stepName !== "fx.record") return null;
  try {
    const { data } = JSON.parse(new TextDecoder().decode(request.eventData.input));
    return recordEvents(new Uint8Array(Buffer.from(data, "base64")));
  } catch {
    return null;
  }
}

// The World, with the same steps as fileStore around each record write.
// libfx writes a session's records one at a time, in order.
function steppedWorld(world, step) {
  const create = async (runId, request, params) => {
    const events = recordStepEvents(request);
    if (!Array.isArray(events)) return world.events.create(runId, request, params);
    await step(`journal_before:${events.map((event) => event.type).join("+")}`);
    const result = await world.events.create(runId, request, params);
    await step("journal_after");
    return result;
  };
  return {
    ...world,
    queue: world.queue.bind(world),
    events: { ...world.events, create, list: world.events.list.bind(world.events) },
  };
}

// Every journal event a World session holds: the records its store loads.
async function worldEvents(world, runId) {
  const { journal = [] } = await worldPersistence(world, { runId }).load();
  return journal.flatMap((record) => recordEvents(record.data));
}

async function worker() {
  // Steps can wait at the same time (a tool's effect and the turn's
  // tool_start event). The parent acks in the order steps were printed, so
  // waiters resolve first in, first out.
  const lines = createInterface({ input: process.stdin });
  let pendingAcks = 0;
  const waiters = [];
  lines.on("line", () => {
    if (waiters.length > 0) waiters.shift()();
    else pendingAcks += 1;
  });
  let stepCount = 0;
  const step = async (name) => {
    stepCount += 1;
    process.stdout.write(`${JSON.stringify({ step: stepCount, name })}\n`);
    if (pendingAcks > 0) {
      pendingAcks -= 1;
      return;
    }
    await new Promise((resolveAck) => { waiters.push(resolveAck); });
  };
  let stepping = false;
  let crashTurn = null;
  let followed = null;
  const sendInputs = () => {
    if (!options.inputs || !crashTurn || followed) return;
    const acks = join(options.dir, "acks.log");
    crashTurn.steer(steerText).then(() => {
      appendFileSync(acks, "steer\n");
      return step("steer_acked");
    }, () => {});
    followed = agent.followUp(followUpText);
    followed.accepted.then(() => {
      appendFileSync(acks, "follow_up\n");
      return step("follow_up_acked");
    }, () => {});
    followed.catch(() => {});
  };
  const run = async (name, _input, context) => {
    sendInputs();
    if (stepping) await step(`before_effect:${name}`);
    // StartsWithDurableIntent: the journal already holds this call.
    const stored = worldMode
      ? (await worldEvents(world, agent.sessionId))
        .some((event) => event.type === "tool_intent" && event.data.some((call) => call.id === context?.executionId))
      : intentStored(join(options.dir, "journal.jsonl"), context?.executionId);
    if (journaled && !stored) {
      appendFileSync(join(options.dir, "effects.log"), `intent_missing:${name}\n`);
    }
    appendFileSync(join(options.dir, "effects.log"), `${name}\n`);
    if (stepping) await step(`after_effect:${name}`);
    return `${name}:ok`;
  };
  const stepWhenStepping = (name) => (stepping ? step(name) : undefined);
  const world = worldMode ? openWorld() : null;
  await world?.start?.();
  const persistence = worldMode
    ? worldPersistence(steppedWorld(world, stepWhenStepping))
    : journaled ? fileStore(join(options.dir, "journal.jsonl"), stepWhenStepping) : undefined;
  const agent = await createFxEngine(await agentOptions({
    backend: options.backend,
    fetch: scriptedFetch({ stepsFor }),
    tools: hostTools(run),
    persistence,
    sessionId: persistence?.runId,
  }));
  if (worldMode) writeFileSync(join(options.dir, "session.txt"), persistence.runId);
  for (let index = 0; index < setupTurns; index += 1) {
    const setup = agent.prompt(`workload=no-tool setup ${index}`);
    for await (const _ of setup) {}
    await setup.result;
  }
  if (!journaled) writeFileSync(join(options.dir, "checkpoint.bin"), await agent.checkpoint());
  process.stdout.write(`${JSON.stringify({ ready: true })}\n`);
  stepping = true;
  try {
    const turn = agent.prompt(`workload=${options.workload} crash`);
    crashTurn = turn;
    await step("prompt_sent");
    let sawText = false;
    for await (const event of turn) {
      if (event.type === "text_delta") {
        if (sawText) continue;
        sawText = true;
      }
      if (event.type === "text_delta" || event.type === "tool_start" || event.type === "tool_end") await step(`event:${event.type}`);
    }
    await turn.result;
    await step("result");
    if (followed) {
      const next = await followed;
      for await (const _ of next) {}
      await next.result;
      await step("follow_up_result");
    }
    await agent.close();
  } catch (error) {
    // A worker released after a takeover (--race) stops on the fence.
    if (error?.cause?.code !== "FX_FENCED") throw error;
    process.stdout.write(`${JSON.stringify({ fenced: true })}\n`);
    await agent.close().catch(() => {});
  } finally {
    if (world) await closeWorld(world);
    // The ack reader keeps stdin open; release it so the worker can exit.
    lines.close();
    process.stdin.destroy();
  }
}

// The session's journal as its contiguous events, for comparing two points.
async function inspect() {
  let events;
  if (worldMode) {
    const world = openWorld();
    await world.start?.();
    events = await worldEvents(world, readFileSync(join(options.dir, "session.txt"), "utf8"));
    await closeWorld(world);
  } else {
    events = readEvents(join(options.dir, "journal.jsonl"));
  }
  const fingerprint = events.map((event) => `${event.seq}:${event.type}:${event.turn}`).join(",");
  process.stdout.write(`${JSON.stringify({ summary: { fingerprint, lastSeq: events.at(-1)?.seq ?? 0 } })}\n`);
}

async function restorer() {
  const requests = [];
  const run = async (name) => {
    appendFileSync(join(options.dir, "effects.log"), `${name}\n`);
    return `${name}:ok`;
  };
  const checkpointPath = join(options.dir, "checkpoint.bin");
  const journalPath = join(options.dir, "journal.jsonl");
  const world = worldMode ? openWorld() : null;
  await world?.start?.();
  const runId = worldMode ? readFileSync(join(options.dir, "session.txt"), "utf8") : undefined;
  const opened = [];
  const open = async () => createFxEngine({
    ...await agentOptions({
      backend: options.backend,
      fetch: scriptedFetch({ stepsFor, onRequest: (request) => requests.push(request) }),
      tools: hostTools(run),
      checkpoint: !journaled && existsSync(checkpointPath) ? readFileSync(checkpointPath) : undefined,
      persistence: worldMode ? worldPersistence(world, { runId }) : journaled ? fileStore(journalPath) : undefined,
      sessionId: runId,
    }),
    onEvent: (event) => { if (event.type === "journal.open") opened.push(event); },
  });
  let journalFolds = true;
  let agent;
  try {
    agent = await open();
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ summary: { completed: false, rememberedSetup: false, resultCounts: {}, journalFolds: false, error: String(error?.message ?? error) } })}\n`);
    if (world) await closeWorld(world);
    return;
  }
  // The setup turn is always committed. A second committed turn means the
  // crashed turn finished before the kill; an open one is resumed.
  // The setup turns, then the crash turn; a follow-up may have committed one more.
  const committedBeforeOpen = journaled && opened[0]?.turns >= setupTurns + 1;
  let result = { stopReason: "end_turn" };
  const resumed = journaled ? agent.resume() : null;
  if (resumed) {
    for await (const _ of resumed) {}
    result = await resumed.result;
  } else if (!committedBeforeOpen) {
    const turn = agent.prompt(`workload=${options.workload} crash`);
    for await (const _ of turn) {}
    result = await turn.result;
  }
  if (journaled) {
    // Follow-ups the journal held run before the check.
    await resumeAll(agent);
    // Every turn so far must reach the model; a check prompt shows them.
    const check = agent.prompt("workload=no-tool check");
    for await (const _ of check) {}
    await check.result;
  }
  await agent.close();
  if (journaled) {
    try {
      await (await open()).close();
    } catch {
      journalFolds = false;
    }
  }
  if (world) await closeWorld(world);
  const prompt = requests.at(-1)?.body.prompt ?? [];
  const resultCounts = {};
  for (const id of toolResultIds(prompt)) resultCounts[id] = (resultCounts[id] ?? 0) + 1;
  process.stdout.write(`${JSON.stringify({
    summary: {
      completed: result.stopReason === "end_turn",
      rememberedSetup: prompt.some((message) => message.role === "user" && textOf(message).includes("setup")),
      resultCounts,
      journalFolds,
      committedBeforeOpen,
      ...inputCounts(prompt),
    },
  })}\n`);
}

// Parent: orchestration only.

function runChild(role, settings) {
  return startChild(role, settings).done;
}

// `holdAt` leaves the child waiting at step k until `release()`, which acks
// every step it printed meanwhile and every later one.
function startChild(role, { backend, workload, dir, killAt = Infinity, holdAt = Infinity }) {
  const execArgs = !process.versions.bun && backend === "wasm" ? ["--experimental-wasm-jspi"] : [];
  const child = spawn(process.execPath, [...execArgs, scriptPath, "--child", role, "--mode", options.mode, "--world-root", options["world-root"], ...(options.inputs ? ["--inputs"] : []), "--backend", backend, "--workload", workload, "--dir", dir], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const steps = [];
  let summary = null;
  let killedAt = null;
  let heldAt = null;
  let unacked = 0;
  let released = false;
  let fenced = false;
  let reachHold;
  const held = new Promise((resolveHeld) => { reachHold = resolveHeld; });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(-4096); });
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    if (message.summary) summary = message.summary;
    if (message.fenced) fenced = true;
    if (message.step === undefined) return;
    steps.push(message.name);
    if (message.step >= killAt && killedAt === null) {
      killedAt = message.name;
      child.kill("SIGKILL");
    } else if (message.step >= holdAt && !released) {
      unacked += 1;
      if (heldAt === null) {
        heldAt = message.name;
        reachHold();
      }
    } else child.stdin.write("go\n");
  });
  const timer = setTimeout(() => child.kill("SIGKILL"), Number(options["timeout-ms"]));
  const done = new Promise((resolveChild) => {
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      reachHold();
      resolveChild({ code, signal, steps, killedAt, heldAt, fenced, summary, stderr });
    });
  });
  return {
    done,
    held,
    release() {
      released = true;
      for (; unacked > 0; unacked -= 1) child.stdin.write("go\n");
    },
  };
}

async function parent() {
  const backends = listOption(options.backends);
  const workloads = listOption(options.workloads);
  // Children get the JSPI flag themselves; the parent only orchestrates.
  for (const backend of backends) if (!new Set(["native", "wasm"]).has(backend)) throw new Error(`unknown backend: ${backend}`);
  for (const workload of workloads) if (!durableWorkloads[workload]) throw new Error(`unknown workload: ${workload}`);

  const report = {
    format_version: 1,
    mode: options.mode,
    race: options.race,
    inputs: options.inputs,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    groups: [],
    violations_by_invariant: {},
    cells: 0,
    failing_cells: 0,
    // Batching can make a run shorter than the clean one, so step k may not
    // exist in it; such a cell tests nothing and is counted apart.
    skipped_cells: 0,
  };
  for (const backend of backends) {
    for (const workload of workloads) {
      const scratch = mkdtempSync(join(tmpdir(), "libfx-crash-"));
      const clean = await runChild("worker", { backend, workload, dir: scratch });
      rmSync(scratch, { recursive: true, force: true });
      if (clean.code !== 0) {
        throw new Error(`${backend} ${workload} clean run failed (${clean.code} ${clean.signal}) after steps [${clean.steps.join(", ")}]: ${clean.stderr}`);
      }
      const group = { backend, workload, steps: clean.steps, cells: [] };
      for (let k = 1; k <= clean.steps.length; k += 1) {
        const dir = mkdtempSync(join(tmpdir(), "libfx-crash-"));
        try {
          let crashed;
          let restored;
          let race = null;
          if (options.race) {
            const worker = startChild("worker", { backend, workload, dir, holdAt: k });
            await worker.held;
            restored = await runChild("restorer", { backend, workload, dir });
            const before = await runChild("inspect", { backend, workload, dir });
            worker.release();
            crashed = await worker.done;
            const after = await runChild("inspect", { backend, workload, dir });
            race = { before: before.summary ?? null, after: after.summary ?? null };
          } else {
            crashed = await runChild("worker", { backend, workload, dir, killAt: k });
          }
          const stoppedAt = options.race ? crashed.heldAt : crashed.killedAt;
          if (stoppedAt === null && crashed.steps.length < k) {
            report.skipped_cells += 1;
            group.cells.push({ k, skipped: true, steps: crashed.steps.length });
            continue;
          }
          if (!options.race) restored = await runChild("restorer", { backend, workload, dir });
          const effects = existsSync(join(dir, "effects.log")) ? readFileSync(join(dir, "effects.log"), "utf8").split("\n").filter(Boolean) : [];
          const cell = {
            k,
            killed_at: stoppedAt,
            killed: options.race ? crashed.heldAt !== null : crashed.signal === "SIGKILL",
            ...(race ? { worker_exit: crashed.code, worker_fenced: crashed.fenced } : {}),
            restorer_exit: restored.code,
            send_effects: effects.filter((name) => name === "send_email").length,
            effects: effects.filter((name) => !name.startsWith("intent_missing:")).length,
            ...(restored.summary ?? { completed: false, rememberedSetup: false, resultCounts: {} }),
          };
          cell.violations = checkCrashCell({
            workload,
            sendEffects: cell.send_effects,
            completed: cell.completed && restored.code === 0,
            rememberedSetup: cell.rememberedSetup,
            resultCounts: cell.resultCounts,
          });
          if (!cell.killed) cell.violations.push(`Harness: worker was not ${options.race ? "held" : "killed"} at step ${k} (${crashed.code} ${crashed.signal})`);
          if (options.inputs) {
            const acks = existsSync(join(dir, "acks.log")) ? readFileSync(join(dir, "acks.log"), "utf8").split("\n").filter(Boolean) : [];
            cell.acks = acks;
            for (const [kind, count] of [["steer", cell.steers ?? 0], ["follow_up", cell.followUps ?? 0]]) {
              if (acks.includes(kind) && count === 0) cell.violations.push(`AckedAreDurable: the acknowledged ${kind} never reached the model`);
              if (count > 1) cell.violations.push(`PlacedOnce: the ${kind} reached the model ${count} times`);
            }
          }
          if (race) {
            const { before, after } = race;
            if (crashed.code !== 0) cell.violations.push(`Harness: the released worker failed (${crashed.code} ${crashed.signal}): ${crashed.stderr.slice(-300)}`);
            if (!before || before.fingerprint !== after?.fingerprint) cell.violations.push("FencedNeverWrites: the released worker changed the session");
          }
          if (journaled) {
            const missing = effects.filter((name) => name.startsWith("intent_missing:")).length;
            if (missing) cell.violations.push(`StartsWithDurableIntent: ${missing} call(s) started before their intent was stored`);
            if (!cell.journalFolds) cell.violations.push(`JournalFolds: the journal did not reopen${cell.error ? ` (${cell.error})` : ""}`);
          }
          for (const violation of cell.violations) {
            const name = violation.split(":")[0];
            report.violations_by_invariant[name] = (report.violations_by_invariant[name] ?? 0) + 1;
          }
          report.cells += 1;
          if (cell.violations.length) report.failing_cells += 1;
          group.cells.push(cell);
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      }
      report.groups.push(group);
    }
  }
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (options["require-clean"] && report.failing_cells > 0) process.exitCode = 1;
}
