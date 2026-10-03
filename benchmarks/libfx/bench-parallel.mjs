#!/usr/bin/env node
// Parallel tool stress and fault injection. Each turn asks for one batch of
// tool calls drawn from a seeded PRNG: random writer flags, latencies and
// thrown errors, and sometimes a cancel while the batch runs. Every batch is
// checked from the real start and end order of the tools and the order the
// next model request carried their results. The WebAssembly core runs host
// tools one at a time, which satisfies every check; the report's concurrency
// and speedup show how much parallelism each backend has.
import { createFxAgent, supportsJspi } from "../../sdk/node.js";
import {
  batchSteps,
  checkBatch,
  durableTools,
  durableWorkloads,
  maxConcurrency,
  nextRandom,
  promptDirectives,
  randomBatch,
  toolResultIds,
} from "./durable.mjs";
import { agentOptions, hostTools, parseArgs, scriptedFetch, sleep } from "./durable-host.mjs";
import { sampleStats } from "./workload.mjs";

const options = parseArgs(process.argv.slice(2), {
  backend: "native",
  batches: "200",
  seed: "1",
  "cancel-rate": "0.05",
  "agent-turns": "50",
});
const backend = options.backend;
const batches = Number(options.batches);
const seed = Number(options.seed) >>> 0;
const cancelRate = Number(options["cancel-rate"]);
const agentTurns = Number(options["agent-turns"]);
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("--backend must be native or wasm");
if (backend === "wasm" && !supportsJspi()) throw new Error("Wasm needs JSPI; run Node with --experimental-wasm-jspi");
if (!Number.isInteger(batches) || batches < 1 || !Number.isInteger(agentTurns) || agentTurns < 1) throw new Error("invalid counts");
if (!(cancelRate >= 0 && cancelRate <= 1)) throw new Error("--cancel-rate must be 0..1");

// Fixed batches first: the list-then-read order check and write-then-read.
const fixed = ["list-then-read", "write-then-read"].map((name) => ({
  name,
  calls: durableWorkloads[name][0].calls.map((call) => ({ name: call.name, writes: durableTools[call.name].writes, latencyMs: 2, fault: null })),
}));

function batchFor(directives) {
  if (directives.fixed) return fixed.find((batch) => batch.name === directives.fixed);
  return randomBatch(Number(directives.batch));
}

const stepsFor = (prompt) => {
  const directives = promptDirectives(prompt);
  const batch = batchFor(directives);
  if (directives.fixed) {
    return [{ calls: batch.calls.map((call, index) => ({ name: call.name, input: { call: index, latencyMs: call.latencyMs, fault: null } })) }, { text: ["done"] }];
  }
  return batchSteps(batch);
};

let current = null;
const requests = [];

async function run(_name, input, { signal }) {
  const state = current;
  if (!state) throw new Error("tool ran outside a batch");
  if (state.cancelled) state.startsAfterCancel += 1;
  state.trace.push({ call: input.call, kind: "start" });
  state.onStart?.();
  try {
    await sleep(input.latencyMs, signal);
    if (input.fault === "throw") throw new Error(`injected fault in call ${input.call}`);
    return `call:${input.call}`;
  } finally {
    state.trace.push({ call: input.call, kind: "end" });
  }
}

async function openAgent() {
  return createFxAgent(await agentOptions({
    backend,
    fetch: scriptedFetch({ stepsFor, onRequest: (request) => requests.push(request) }),
    tools: hostTools(run),
  }));
}

const plan = [
  ...fixed.map((batch) => ({ prompt: `fixed=${batch.name}`, batch, cancel: false })),
];
let state = seed;
for (let index = 0; index < batches; index += 1) {
  const drawn = nextRandom(state);
  state = drawn.seed;
  const cancelDraw = nextRandom(state);
  state = cancelDraw.seed;
  plan.push({ prompt: `batch=${drawn.seed}`, batch: randomBatch(drawn.seed), cancel: cancelDraw.value < cancelRate });
}

const results = [];
let agent = await openAgent();
let turnsOnAgent = 0;
try {
  for (const entry of plan) {
    if (turnsOnAgent >= agentTurns) {
      await agent.close();
      agent = await openAgent();
      turnsOnAgent = 0;
    }
    turnsOnAgent += 1;
    const requestsBefore = requests.length;
    current = { trace: [], cancelled: false, startsAfterCancel: 0, onStart: null };
    const startedAt = performance.now();
    const turn = agent.prompt(entry.prompt);
    if (entry.cancel) {
      current.onStart = () => {
        current.onStart = null;
        current.cancelled = true;
        turn.cancel();
      };
    }
    for await (const _ of turn) {}
    const outcome = await turn.result;
    const wallMs = performance.now() - startedAt;
    const turnRequests = requests.slice(requestsBefore);
    const toolRequest = turnRequests.find(({ frames }) => frames.some((frame) => frame.type === "tool-call"));
    const followUp = turnRequests[turnRequests.indexOf(toolRequest) + 1];
    const expectedOrder = toolRequest ? toolRequest.frames.filter((frame) => frame.type === "tool-call").map((frame) => frame.toolCallId) : [];
    const violations = [];
    if (entry.cancel) {
      if (current.startsAfterCancel > 0) violations.push(`CancelStopsBatch: ${current.startsAfterCancel} calls started after cancel`);
    } else {
      if (outcome.stopReason !== "end_turn") violations.push(`TurnCompletes: stopped with ${outcome.stopReason}`);
      violations.push(...checkBatch({
        writes: entry.batch.calls.map((call) => call.writes),
        trace: current.trace,
        resultOrder: followUp ? toolResultIds(followUp.body.prompt) : [],
        expectedOrder,
      }));
    }
    const latencySum = entry.batch.calls.reduce((total, call) => total + call.latencyMs, 0);
    results.push({
      prompt: entry.prompt,
      size: entry.batch.calls.length,
      writers: entry.batch.calls.filter((call) => call.writes).length,
      cancelled: entry.cancel,
      stop_reason: outcome.stopReason,
      max_concurrency: maxConcurrency(current.trace),
      latency_sum_ms: latencySum,
      wall_ms: wallMs,
      violations,
    });
    current = null;
  }
} finally {
  await agent.close();
}

const checked = results.filter((result) => !result.cancelled);
const failing = results.filter((result) => result.violations.length > 0);
const report = {
  format_version: 1,
  runtime: process.versions.bun ? "bun" : "node",
  runtime_version: process.versions.bun ?? process.version,
  backend,
  seed,
  batches: results.length,
  cancelled: results.length - checked.length,
  failing_batches: failing.length,
  max_concurrency: sampleStats(checked.map((result) => result.max_concurrency)),
  readers_overlapped: checked.some((result) => result.max_concurrency > 1),
  wall_over_latency_sum: sampleStats(checked.filter((result) => result.latency_sum_ms > 0).map((result) => result.wall_ms / result.latency_sum_ms)),
  fixed: results.slice(0, fixed.length),
  failures: failing.slice(0, 20),
};
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
if (failing.length > 0) process.exitCode = 1;
