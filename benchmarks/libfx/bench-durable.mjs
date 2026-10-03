#!/usr/bin/env node
// Durable libfx benchmark: what a journal costs per turn, per tool call and
// per restore, against the same workloads with no durability.
//
// "control" runs each scripted workload with no durability. "today-rN"
// emulates a host that makes libfx durable from outside, on a remote log with an N ms
// round trip: four sequential acknowledged writes per tool call and a
// checkpoint after each turn (durable.mjs todayAdapterWrites). "journal-rN"
// gives libfx a journal on the same remote log, which acks appends in call
// order N ms after each call: tools wait on nothing, and the turn ends once
// every append it started has landed. Appends overlap, so journal rows report
// append calls instead of awaited writes. The restore section
// measures checkpoint and journal size and restore time against history
// length. With --world-root (a directory holding @workflow/world-local),
// "world-local" runs libfx with `world` on a world-local World.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createFxAgent, supportsJspi } from "../../sdk/node.js";
import { durableWorkloads, promptDirectives, todayAdapterWrites, toolCallsIn } from "./durable.mjs";
import { agentOptions, hostTools, listOption, parseArgs, scriptedFetch, sleep } from "./durable-host.mjs";
import { sampleStats } from "./workload.mjs";

const options = parseArgs(process.argv.slice(2), {
  backend: "native",
  samples: "30",
  warmups: "3",
  rtt: "0,5,25",
  "tool-ms": "10",
  history: "10,100",
  "restore-samples": "10",
  workloads: Object.keys(durableWorkloads).join(","),
  "world-root": "",
});
const backend = options.backend;
const samples = Number(options.samples);
const warmups = Number(options.warmups);
const toolMs = Number(options["tool-ms"]);
const roundTrips = listOption(options.rtt).map(Number);
const histories = listOption(options.history).map(Number);
const restoreSamples = Number(options["restore-samples"]);
const workloads = listOption(options.workloads);
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("--backend must be native or wasm");
if (backend === "wasm" && !supportsJspi()) throw new Error("Wasm needs JSPI; run Node with --experimental-wasm-jspi");
for (const value of [samples, warmups, toolMs, restoreSamples, ...roundTrips, ...histories]) {
  if (!Number.isInteger(value) || value < 0 || value > 10_000) throw new Error(`invalid numeric option: ${value}`);
}
for (const name of workloads) if (!durableWorkloads[name]) throw new Error(`unknown workload: ${name}`);

const createWorld = options["world-root"]
  ? (await import(pathToFileURL(join(options["world-root"], "node_modules/@workflow/world-local/dist/index.js")).href)).createWorld
  : null;

const stepsFor = (prompt) => durableWorkloads[promptDirectives(prompt).workload] ?? durableWorkloads["no-tool"];

// A journal on a remote log: each append lands one round trip after its
// call, and never before the call ahead of it.
function remoteJournal(roundTrip, events = []) {
  const stored = [...events];
  let previous = Promise.resolve();
  const journal = {
    stored,
    appends: 0,
    bytes: 0,
    append(batch) {
      journal.appends += 1;
      journal.bytes += JSON.stringify(batch).length;
      const landed = Promise.all([previous, roundTrip ? sleep(roundTrip) : null]).then(() => { stored.push(...batch); });
      previous = landed;
      return landed;
    },
    async load() { return { events: stored.slice() }; },
  };
  return journal;
}

const turnBytes = (events, turn) => events
  .filter((event) => event.turn === turn)
  .reduce((sum, event) => sum + JSON.stringify(event).length, 0);

// A World that counts libfx's journal writes as a journal counts appends.
function countingWorld(inner) {
  const counter = { appends: 0, bytes: 0 };
  const create = (runId, request, params) => {
    if (request?.eventData?.stepName === "libfx.journal") {
      counter.appends += 1;
      counter.bytes += request.eventData.input.byteLength;
    }
    return inner.events.create(runId, request, params);
  };
  counter.world = {
    ...inner,
    queue: inner.queue.bind(inner),
    events: { ...inner.events, create, list: inner.events.list.bind(inner.events) },
  };
  return counter;
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

// One agent whose tools record their real start and end times on `active`.
async function openAgent({ roundTrip = null, checkpoint, journal, world } = {}) {
  let active = null;
  const run = async (name, input, { signal }) => {
    const row = active;
    if (roundTrip !== null) {
      for (let write = 0; write < todayAdapterWrites(1).perToolBefore; write += 1) {
        await sleep(roundTrip);
        if (row) row.awaited_writes += 1;
      }
    }
    if (row) row.exec_first_start ??= performance.now();
    await sleep(toolMs, signal);
    if (row) row.exec_last_end = performance.now();
    if (roundTrip !== null) {
      for (let write = 0; write < todayAdapterWrites(1).perToolAfter; write += 1) {
        await sleep(roundTrip);
        if (row) row.awaited_writes += 1;
      }
    }
    return `${name}:ok`;
  };
  const agent = await createFxAgent(await agentOptions({
    backend,
    fetch: scriptedFetch({ stepsFor }),
    tools: hostTools(run),
    checkpoint,
    journal,
    world: world?.world,
  }));
  return { agent, journal: journal ?? world, setActive: (row) => { active = row; } };
}

async function runTurn(handle, workload, index, roundTrip) {
  const row = {
    prompt_at: performance.now(),
    first_output_at: null,
    last_tool_end_at: null,
    text_after_tool_at: null,
    exec_first_start: null,
    exec_last_end: null,
    completed_at: null,
    awaited_writes: 0,
    checkpoint_bytes: null,
    journal_bytes: null,
    append_calls: null,
  };
  const appendsBefore = handle.journal?.appends ?? 0;
  const bytesBefore = handle.journal?.bytes ?? 0;
  handle.setActive(row);
  const turn = handle.agent.prompt(`workload=${workload} sample=${index}`);
  for await (const event of turn) {
    if (event.type === "text_delta" || event.type === "tool_start") row.first_output_at ??= performance.now();
    if (event.type === "tool_end") row.last_tool_end_at = performance.now();
    if (event.type === "text_delta" && row.last_tool_end_at !== null) row.text_after_tool_at ??= performance.now();
  }
  const result = await turn.result;
  if (result.stopReason !== "end_turn") throw new Error(`${workload} stopped with ${result.stopReason}`);
  if (roundTrip !== null) {
    const bytes = await handle.agent.checkpoint();
    await sleep(roundTrip);
    row.awaited_writes += todayAdapterWrites(0).perTurn;
    row.checkpoint_bytes = bytes.byteLength;
  }
  if (handle.journal) {
    row.awaited_writes = null;
    row.append_calls = handle.journal.appends - appendsBefore;
    row.journal_bytes = handle.journal.bytes - bytesBefore;
  }
  row.completed_at = performance.now();
  handle.setActive(null);
  return row;
}

const stats = (values) => {
  const present = values.filter((value) => value !== null && Number.isFinite(value));
  return present.length ? sampleStats(present) : null;
};

function summarize(rows) {
  return {
    prompt_to_first_output_ms: stats(rows.map((row) => row.first_output_at - row.prompt_at)),
    turn_ms: stats(rows.map((row) => row.completed_at - row.prompt_at)),
    tool_to_next_text_ms: stats(rows.map((row) => (row.text_after_tool_at === null ? null : row.text_after_tool_at - row.last_tool_end_at))),
    batch_wall_ms: stats(rows.map((row) => (row.exec_first_start === null ? null : row.exec_last_end - row.exec_first_start))),
    awaited_writes: stats(rows.map((row) => row.awaited_writes)),
    checkpoint_bytes: stats(rows.map((row) => row.checkpoint_bytes)),
    journal_bytes: stats(rows.map((row) => row.journal_bytes)),
    append_calls: stats(rows.map((row) => row.append_calls)),
  };
}

async function measure(workload, roundTrip, journal, world) {
  const durable = journal !== undefined || world !== undefined;
  const handle = durable ? await openAgent({ journal, world }) : await openAgent({ roundTrip });
  try {
    const rows = [];
    for (let index = -warmups; index < samples; index += 1) {
      const row = await runTurn(handle, workload, index, durable ? null : roundTrip);
      if (index >= 0) rows.push(row);
    }
    return summarize(rows);
  } finally {
    await handle.agent.close();
  }
}

const report = {
  format_version: 1,
  runtime: process.versions.bun ? "bun" : "node",
  runtime_version: process.versions.bun ?? process.version,
  backend,
  options: { samples, warmups, tool_ms: toolMs, round_trips_ms: roundTrips, histories, restore_samples: restoreSamples },
  workloads: {},
  restore: [],
};

for (const workload of workloads) {
  const modes = { control: await measure(workload, null) };
  for (const roundTrip of roundTrips) {
    modes[`today-r${roundTrip}`] = await measure(workload, roundTrip);
    modes[`today-r${roundTrip}`].planned_awaited_writes = todayAdapterWrites(toolCallsIn(durableWorkloads[workload])).awaited;
    modes[`journal-r${roundTrip}`] = await measure(workload, roundTrip, remoteJournal(roundTrip));
  }
  if (createWorld) {
    const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-bench-world-")), recoverActiveRuns: false });
    await world.start?.();
    try {
      modes["world-local"] = await measure(workload, null, undefined, countingWorld(world));
    } finally {
      await closeWorld(world);
    }
  }
  report.workloads[workload] = modes;
}

for (const history of histories) {
  const journal = remoteJournal(0);
  const handle = await openAgent({ journal });
  let checkpoint;
  let lastTurnJournalBytes = 0;
  const checkpointMs = [];
  try {
    for (let index = 0; index < history; index += 1) {
      const row = await runTurn(handle, "no-tool", index, null);
      lastTurnJournalBytes = row.journal_bytes;
    }
    // One tool turn after `history` turns; turns count from 1.
    await runTurn(handle, "one-safe", history, null);
    for (let index = 0; index < restoreSamples; index += 1) {
      const startedAt = performance.now();
      checkpoint = await handle.agent.checkpoint();
      checkpointMs.push(performance.now() - startedAt);
    }
  } finally {
    await handle.agent.close();
  }
  const restoreMs = [];
  const journalRestoreMs = [];
  const createMs = [];
  for (let index = 0; index < restoreSamples; index += 1) {
    let startedAt = performance.now();
    const restored = await openAgent({ checkpoint });
    restoreMs.push(performance.now() - startedAt);
    await restored.agent.close();
    startedAt = performance.now();
    const replayed = await openAgent({ journal: remoteJournal(0, journal.stored) });
    journalRestoreMs.push(performance.now() - startedAt);
    await replayed.agent.close();
    startedAt = performance.now();
    const fresh = await openAgent();
    createMs.push(performance.now() - startedAt);
    await fresh.agent.close();
  }
  report.restore.push({
    history_turns: history,
    checkpoint_bytes: checkpoint.byteLength,
    checkpoint_bytes_per_turn: checkpoint.byteLength / Math.max(history, 1),
    checkpoint_ms: sampleStats(checkpointMs),
    journal_events: journal.stored.length,
    journal_bytes: JSON.stringify(journal.stored).length,
    journal_last_turn_bytes: lastTurnJournalBytes,
    restore_create_ms: sampleStats(restoreMs),
    journal_restore_create_ms: sampleStats(journalRestoreMs),
    one_tool_turn_journal_bytes: turnBytes(journal.stored, history + 1),
    fresh_create_ms: sampleStats(createMs),
  });
}

process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
