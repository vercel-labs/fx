#!/usr/bin/env bun
// Drives libfx's real durable code on local() with slow chunk writes, and has
// TLC check each run against tests/tla/sdk/UiStreamOrder.tla through
// UiStreamOrderTrace.tla, with the constants of local() as it is now: one
// chunk per call, a World that lands them in any order, and a reader that
// lists every chunk on disk.
//
//   bun tests/tla/drivers/sdk/ui-order.ts                       # every named edge case
//   bun tests/tla/drivers/sdk/ui-order.ts --scenario slow-first # one of them
//   bun tests/tla/drivers/sdk/ui-order.ts --fuzz 20 --seed 7    # seeded random schedules
//   bun tests/tla/drivers/sdk/ui-order.ts --scenario-file f.json # a saved case
//   bun tests/tla/drivers/sdk/ui-order.ts --old-model           # check the model against the code before the fix
//
// A scenario is a scripted harness (no model, no fx process, nothing leaves
// the machine) whose turn pushes its words in waves, on a local() folder in
// the temp folder, and the delay of each word's chunk write. The delay is
// the whole fault: the chunk's bytes are the ones libfx wrote, and it lands
// late. The run's events are what libfx asked the World to write, when
// each call returned, and what a reader open from the start showed.
//
// Besides TLC, each run checks what a viewer sees directly: the live reader,
// the turn's own events, a reader that comes after, and a reconnect from the
// middle show the words in order, and libfx called the World with one chunk
// at a time. A scenario's events, observed module, and TLC log go to a
// folder under FX_TLA_OUT or the system temp folder. A rejected or failed
// fuzz case is saved there as scenario.json. Exits 1 when a run is rejected.
//
// With --old-model the run is checked against libfx as it was before the fix
// (a batch in one writeMulti call), the model of UiStreamOrder-ParallelMulti.
// It shows the trace and the model agree on what the old code did, a reader
// that showed a late chunk after the ones behind it included: TLC must accept
// the run, and what the viewer saw is only reported. Run it on a checkout
// without the fix.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";
// libfx's modules are plain JavaScript.
import { createDurableAgentFactory, memory } from "../../../../sdk/durable.js";
import { local } from "../../../../sdk/durable/local.mjs";
import { burstHarness, burstWord, slowChunkWrites, watchStreamWrites } from "../../../../sdk/tests/ui-order-fixtures.mjs";

// No fx process runs here; these keep anything libfx reads off the developer's profile.
process.env.FX_SOUND = "0";
process.env.FX_DISABLE_KEYCHAIN = "1";
process.env.FX_HOME = mkdtempSync(join(tmpdir(), "fx-ui-order-home-"));

type Scenario = {
  name: string;
  // The words each wave pushes; a wave comes `gapMs` after the one before it.
  waves: number[];
  gapMs?: number;
  // Word index to the milliseconds its chunk write is late.
  slow: Record<number, number>;
};
type Observed = { op: "issue"; chunks: number[] } | { op: "return" } | { op: "deliver"; chunk: number };

const args = process.argv.slice(2);
const oldModel = args.includes("--old-model");
const option = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};

// Word index 0 is written alone: libfx sends the first line at once and the
// ones pushed while it is written as the next batch. So word 1 is the first
// chunk of the batch, and the last word is its last.
const named: Scenario[] = [
  { name: "slow-first", waves: [6], slow: { 1: 300 } },
  { name: "slow-middle", waves: [6], slow: { 3: 300 } },
  { name: "slow-last", waves: [6], slow: { 5: 300 } },
  { name: "slow-first-and-middle", waves: [6], slow: { 1: 300, 3: 200 } },
  { name: "batch-of-two", waves: [3], slow: { 1: 300 } },
  { name: "one-line", waves: [1], slow: { 0: 200 } },
  { name: "two-waves", waves: [4, 4], gapMs: 100, slow: { 1: 400 } },
  { name: "no-fault", waves: [6], slow: {} },
];

// Seeded, so a failing schedule can be run again: mulberry32.
function random(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fuzzScenarios(count: number, seed: number): Scenario[] {
  const next = random(seed);
  const between = (low: number, high: number) => low + Math.floor(next() * (high - low + 1));
  return Array.from({ length: count }, (_, index) => {
    const waves = Array.from({ length: between(1, 3) }, () => between(1, 6));
    const words = waves.reduce((sum, count) => sum + count, 0);
    const slow: Record<number, number> = {};
    for (let late = between(0, Math.min(4, words)); late > 0; late -= 1) slow[between(0, words - 1)] = between(30, 220);
    return { name: `fuzz-${seed}-${index}`, waves, gapMs: between(0, 3) * 50, slow };
  });
}

const tla = (value: unknown): string =>
  Array.isArray(value) ? `<<${value.map(tla).join(", ")}>>` : typeof value === "string" ? JSON.stringify(value) : String(value);

// A line's identity: no two lines of a scenario's turn share a type and a word.
const keyOf = (event: { type: string; delta?: string }) => `${event.type}:${event.delta ?? ""}`;

// The lines a stream shows, read until `count` have come or it goes quiet.
async function readLines(stream: ReadableStream<Uint8Array>, count: number, onLine: (line: Record<string, any>) => void = () => {}) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const lines: Record<string, any>[] = [];
  let buffered = "";
  while (lines.length < count) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const quiet = new Promise<{ done: true; value?: undefined }>((resolve) => { timer = setTimeout(() => resolve({ done: true }), 4000); });
    const { value, done } = await Promise.race([reader.read(), quiet]);
    clearTimeout(timer);
    if (done) break;
    buffered += decoder.decode(value, { stream: true });
    for (let end = buffered.indexOf("\n"); end >= 0; end = buffered.indexOf("\n")) {
      const line = JSON.parse(buffered.slice(0, end));
      buffered = buffered.slice(end + 1);
      lines.push(line);
      onLine(line);
    }
  }
  await reader.cancel().catch(() => {});
  return lines;
}

const inOrder = (ids: number[], total: number) => ids.length === total && ids.every((id, index) => id === index + 1);

async function runScenario(scenario: Scenario, root: string) {
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(join(tmpdir(), "fx-ui-order-"));
  const words = scenario.waves.reduce((sum, count) => sum + count, 0);
  const total = words + 2; // the turn's start and end lines, and a line per word
  const markers = Object.entries(scenario.slow).map(([index, ms]) => [`"delta":"${burstWord(Number(index))} "`, ms] as const);
  const slow = slowChunkWrites((text: string) => markers.find(([marker]) => text.includes(marker))?.[1] ?? 0);
  const observed: Observed[] = [];
  const idOf = new Map<string, number>();
  const callSizes: number[] = [];
  let written = 0;
  const durability = watchStreamWrites(local({ dir }), (event: { op: string; chunks?: string[] }) => {
    if (event.op === "return") {
      observed.push({ op: "return" });
      return;
    }
    const chunks = (event.chunks ?? []).map((line) => {
      idOf.set(keyOf(JSON.parse(line)), ++written);
      return written;
    });
    callSizes.push(chunks.length);
    observed.push({ op: "issue", chunks });
  });
  const createAgent = createDurableAgentFactory({ harness: burstHarness({ waves: scenario.waves, gapMs: scenario.gapMs ?? 0 }), defaultDurability: async () => memory(), name: "createUiOrderAgent" });
  const agent = createAgent({ durability });
  const problems: string[] = [];
  try {
    const session = agent.session();
    const turn = session.prompt("go", { messageId: "turn-order" });
    const live = readLines(session.stream(0), total, (line) => {
      const chunk = idOf.get(keyOf(line as { type: string; delta?: string }));
      if (chunk !== undefined) observed.push({ op: "deliver", chunk });
    });
    const events: string[] = [];
    for await (const event of turn) if (event.type === "text_delta") events.push(event.delta);
    await turn.result;
    const liveLines = await live;
    slow.restore();
    const replay = await readLines(session.stream(0), total);
    const cursor = replay[Math.floor(replay.length / 2)]?.cursor ?? 0;
    const reconnect = await readLines(session.stream(cursor), replay.length - cursor);

    const wordsOf = (lines: Record<string, any>[]) => lines.filter((line) => line.type === "text_delta").map((line) => line.delta);
    const expected = Array.from({ length: words }, (_, index) => `${burstWord(index)} `);
    const delivered = observed.flatMap((event) => (event.op === "deliver" ? [event.chunk] : []));
    if (slow.delayed.length !== markers.length) problems.push(`the fault was applied ${slow.delayed.length} times, not ${markers.length}`);
    if (!inOrder(delivered, total)) problems.push(`the live reader showed chunks ${delivered.join(",")}, not 1..${total} in order`);
    if (JSON.stringify(wordsOf(liveLines)) !== JSON.stringify(expected)) problems.push(`the live reader's words were ${wordsOf(liveLines).map((word) => word.trim()).join(" ")}`);
    if (JSON.stringify(events) !== JSON.stringify(expected)) problems.push("the turn's own events showed the words out of order");
    if (JSON.stringify(wordsOf(replay)) !== JSON.stringify(expected)) problems.push("a reader that came after showed the words out of order");
    if (JSON.stringify(reconnect) !== JSON.stringify(replay.filter((line) => line.cursor > cursor))) problems.push(`a reconnect from cursor ${cursor} did not show the lines after it`);
    if (!oldModel && callSizes.some((size) => size !== 1)) problems.push(`libfx called the World with ${Math.max(...callSizes)} chunks at once, not one at a time`);
  } catch (error) {
    problems.push(`the run failed: ${(error as Error)?.stack ?? error}`);
  } finally {
    slow.restore();
    await agent.close().catch(() => {});
    rmSync(dir, { recursive: true, force: true });
  }

  writeFileSync(join(root, "UiStreamOrderObserved.tla"), [
    "------------------------- MODULE UiStreamOrderObserved -------------------------",
    `\\* Generated by tests/tla/drivers/sdk/ui-order.ts for ${scenario.name}.`,
    `Observed == <<\n  ${observed.map((event) => `[op |-> ${tla(event.op)}, chunks |-> ${tla("chunks" in event ? event.chunks : [])}, chunk |-> ${"chunk" in event ? event.chunk : 0}]`).join(",\n  ")}\n>>`,
    "=============================================================================",
    "",
  ].join("\n"));
  writeFileSync(join(root, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `    Lines = ${total}`,
    `    WritePolicy = ${oldModel ? '"Multi"' : '"OneByOne"'}`,
    '    WorldLands = "Parallel"',
    '    Reader = "Exists"',
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  // The search ends where no step is left, so a rejected run is not a deadlock.
  const run = await runTlc(root, "UiStreamOrderTrace.tla", "trace.cfg", ["UiStreamOrder.tla", "UiStreamOrderTrace.tla"], join(TLA_ROOT, "sdk"), ["-deadlock"]);
  const accepted = run.violated === "NotAllMatched";
  if (!accepted) problems.push(`TLC rejected the run: the model with ${oldModel ? "the old" : "local()'s"} constants cannot take its ${observed.length} events`);
  return { accepted, problems, events: observed.length, total, delayed: slow.delayed, observed };
}

const fuzz = option("--fuzz");
const only = option("--scenario");
const file = option("--scenario-file");
const seed = Number(option("--seed") ?? "1");
const scenarios = file
  ? [JSON.parse(readFileSync(file, "utf8")) as Scenario]
  : fuzz
    ? fuzzScenarios(Number(fuzz), seed)
    : named.filter((scenario) => !only || scenario.name === only);
if (scenarios.length === 0) {
  console.error(`no scenario named ${only}; the named ones are ${named.map((scenario) => scenario.name).join(", ")}`);
  process.exit(2);
}

const out = outDir("ui-order");
console.log(`output: ${out}${fuzz ? ` (fuzz seed ${seed})` : ""}`);
let rejected = 0;
for (const scenario of scenarios) {
  const root = join(out, scenario.name);
  const started = performance.now();
  const result = await runScenario(scenario, root);
  writeJson(join(root, "result.json"), { scenario, ...result });
  writeJson(join(root, "scenario.json"), scenario);
  const took = ((performance.now() - started) / 1000).toFixed(1);
  if (oldModel) {
    // What the viewer saw is a finding here; only TLC's verdict counts.
    const modelProblems = result.problems.filter((problem) => problem.startsWith("TLC rejected") || problem.startsWith("the run failed"));
    if (modelProblems.length > 0) rejected += 1;
    console.log(`${modelProblems.length === 0 ? "ACCEPTED" : "REJECTED"} ${scenario.name} by the old model (${took}s)${result.problems.length > modelProblems.length ? `; the code showed:\n  ${result.problems.filter((problem) => !modelProblems.includes(problem)).join("\n  ")}` : ""}`);
    continue;
  }
  if (result.accepted && result.problems.length === 0) {
    console.log(`ACCEPTED ${scenario.name}: ${result.events} events, ${result.total} lines, ${result.delayed.length} slow writes (${took}s)`);
  } else {
    rejected += 1;
    console.log(`REJECTED ${scenario.name} (${took}s; saved as ${join(root, "scenario.json")}):\n  ${result.problems.join("\n  ")}`);
  }
}
console.log(`${scenarios.length - rejected}/${scenarios.length} runs accepted`);
process.exit(rejected ? 1 : 0);
