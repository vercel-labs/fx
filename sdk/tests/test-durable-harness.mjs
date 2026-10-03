#!/usr/bin/env node
// The durable libfx harnesses: their pure core on plain data, then a small
// run of each driver (benchmarks/libfx/bench-durable.mjs, bench-parallel.mjs,
// crash-matrix.mjs) on both backends.
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  batchSteps,
  callId,
  checkBatch,
  checkCrashCell,
  durableWorkloads,
  framesFor,
  maxConcurrency,
  nextRandom,
  promptDirectives,
  randomBatch,
  sseBody,
  stepFor,
  toolCallsIn,
  todayAdapterWrites,
  toolResultIds,
  turnNumber,
  turnStartIndex,
} from "../../benchmarks/libfx/durable.mjs";

// The pure core, on plain data.

const user = (text) => ({ role: "user", content: [{ type: "text", text }] });
const steer = (text) => user(`<user_steering>${text}</user_steering>`);
const results = (...ids) => ({ role: "tool", content: ids.map((toolCallId) => ({ type: "tool-result", toolCallId })) });

{
  const prompt = [user("workload=one-safe setup"), { role: "assistant", content: [] }, user("workload=list-then-read go"), steer("faster")];
  assert.equal(turnStartIndex(prompt), 2, "steering never starts a turn");
  assert.equal(turnNumber(prompt), 2);
  assert.deepEqual(promptDirectives(prompt), { workload: "list-then-read" });
  assert.deepEqual(toolResultIds([...prompt, results("a", "b")]), ["a", "b"]);
  assert.deepEqual(toolResultIds([user("x"), results("old"), user("y")]), [], "results before the turn do not count");
}

{
  const steps = durableWorkloads["list-then-read"];
  assert.equal(stepFor(steps, 0), 0);
  assert.equal(stepFor(steps, 2), 1);
  assert.throws(() => stepFor(steps, 1), /partial tool results/);
  assert.throws(() => stepFor(durableWorkloads["no-tool"], 1), /partial tool results/);

  const first = framesFor(steps, [user("workload=list-then-read")]);
  assert.deepEqual(first.filter((frame) => frame.type === "tool-call").map((frame) => frame.toolCallId), [callId(1, 0, 0), callId(1, 0, 1)]);
  assert.equal(first.at(-1).finishReason.unified, "tool-calls");
  const second = framesFor(steps, [user("workload=list-then-read"), results(callId(1, 0, 0), callId(1, 0, 1))]);
  assert.deepEqual(second.map((frame) => frame.type), ["text-delta", "finish"]);
  assert.equal(second.at(-1).finishReason.unified, "stop");
  assert.ok(sseBody(second).endsWith("data: [DONE]\n\n"));
  assert.equal(framesFor(durableWorkloads["stream-200"], [user("x")]).filter((frame) => frame.type === "text-delta").length, 200);
}

{
  assert.deepEqual(nextRandom(7), nextRandom(7), "the PRNG is a pure function of its seed");
  assert.notEqual(nextRandom(7).value, nextRandom(8).value);
  const batch = randomBatch(42);
  assert.deepEqual(batch, randomBatch(42));
  for (let seed = 0; seed < 200; seed += 1) {
    const { calls } = randomBatch(seed);
    assert.ok(calls.length >= 2 && calls.length <= 8);
    for (const call of calls) assert.equal(call.name, call.writes ? "write_item" : "read_item");
  }
  assert.equal(batchSteps(batch)[0].calls.length, batch.calls.length);
}

{
  const ids = ["a", "b", "c"];
  const sequential = [0, 1, 2].flatMap((call) => [{ call, kind: "start" }, { call, kind: "end" }]);
  assert.deepEqual(checkBatch({ writes: [false, true, false], trace: sequential, resultOrder: ids, expectedOrder: ids }), []);
  assert.equal(maxConcurrency(sequential), 1);

  const readersOverlap = [{ call: 0, kind: "start" }, { call: 1, kind: "start" }, { call: 0, kind: "end" }, { call: 1, kind: "end" }];
  assert.deepEqual(checkBatch({ writes: [false, false], trace: readersOverlap, resultOrder: ["a", "b"], expectedOrder: ["a", "b"] }), []);
  assert.equal(maxConcurrency(readersOverlap), 2);

  const writerOverlaps = [{ call: 0, kind: "start" }, { call: 1, kind: "start" }, { call: 1, kind: "end" }, { call: 0, kind: "end" }];
  const writerViolations = checkBatch({ writes: [true, false], trace: writerOverlaps, resultOrder: ["a", "b"], expectedOrder: ["a", "b"] });
  assert.ok(writerViolations.some((violation) => violation.startsWith("WriterRunsAlone")));
  assert.ok(writerViolations.some((violation) => violation.startsWith("NothingPassesWriter")));
  assert.ok(checkBatch({ writes: [false, true], trace: writerOverlaps, resultOrder: ["a", "b"], expectedOrder: ["a", "b"] })
    .some((violation) => violation.startsWith("WriterAfterEarlier")));

  assert.ok(checkBatch({ writes: [false, false], trace: readersOverlap, resultOrder: ["b", "a"], expectedOrder: ["a", "b"] })
    .some((violation) => violation.startsWith("ResultsInModelOrder")), "completion order is not model order");
  assert.ok(checkBatch({ writes: [false, false], trace: readersOverlap, resultOrder: [], expectedOrder: [] })[0].startsWith("ScriptedBatch"));
  assert.ok(checkBatch({ writes: [false], trace: [{ call: 0, kind: "start" }], resultOrder: ["a"], expectedOrder: ["a"] })[0].startsWith("Completeness"));
}

{
  const clean = { workload: "one-never", neverEffects: 1, completed: true, rememberedSetup: true, resultCounts: { a: 1 } };
  assert.deepEqual(checkCrashCell(clean), []);
  assert.match(checkCrashCell({ ...clean, neverEffects: 2 })[0], /^NeverRunsTwice/);
  assert.match(checkCrashCell({ ...clean, completed: false })[0], /^TurnCompletes/);
  assert.match(checkCrashCell({ ...clean, rememberedSetup: false })[0], /^KeepsCommittedHistory/);
  assert.match(checkCrashCell({ ...clean, resultCounts: { a: 2 } })[0], /^OneOutcome/);
  assert.throws(() => checkCrashCell({ ...clean, workload: "nope" }), /unknown workload/);
}

assert.equal(todayAdapterWrites(0).awaited, 1);
assert.equal(todayAdapterWrites(2).awaited, 9);
assert.equal(toolCallsIn(durableWorkloads["write-then-read"]), 2);

// The drivers, small runs on both backends.

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const runtimeArgs = (backend) => (!process.versions.bun && backend === "wasm" ? ["--experimental-wasm-jspi"] : []);
const run = (script, args, backend) => {
  const result = spawnSync(process.execPath, [...runtimeArgs(backend), fileURLToPath(new URL(`../../benchmarks/libfx/${script}`, import.meta.url)), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120_000,
  });
  assert.equal(result.status, 0, `${script} ${backend} failed:\n${result.stderr}`);
  return JSON.parse(result.stdout);
};

for (const backend of ["native", "wasm"]) {
  const durable = run("bench-durable.mjs", ["--backend", backend, "--samples", "2", "--warmups", "0", "--rtt", "0", "--history", "2", "--restore-samples", "2", "--tool-ms", "1"], backend);
  assert.equal(durable.backend, backend);
  for (const [name, steps] of Object.entries(durableWorkloads)) {
    const today = durable.workloads[name]["today-r0"];
    assert.equal(today.awaited_writes.p50, today.planned_awaited_writes, `${name}: counted writes match the adapter plan`);
    assert.equal(durable.workloads[name].control.awaited_writes.max, 0);
    assert.equal(durable.workloads[name].control.batch_wall_ms === null, toolCallsIn(steps) === 0);
  }
  assert.equal(durable.restore[0].history_turns, 2);
  assert.ok(durable.restore[0].checkpoint_bytes > 0);

  const parallel = run("bench-parallel.mjs", ["--backend", backend, "--batches", "12", "--seed", "3"], backend);
  assert.equal(parallel.failing_batches, 0, JSON.stringify(parallel.failures));
  assert.deepEqual(parallel.fixed.map((batch) => batch.violations), [[], []], "list-then-read and write-then-read keep their order");

  const crash = run("crash-matrix.mjs", ["--backends", backend, "--workloads", "one-never"], backend);
  assert.ok(crash.cells >= 5, "one cell per crash step");
  for (const cell of crash.groups[0].cells) {
    assert.ok(cell.killed, `step ${cell.k} was a real SIGKILL`);
    assert.ok(cell.completed && cell.rememberedSetup, `step ${cell.k}: restore finished the turn and kept history`);
  }
  // With a journal, no crash step may run send_email twice or lose the
  // setup turn.
  const journaled = run("crash-matrix.mjs", ["--backends", backend, "--workloads", "one-never", "--mode", "journal", "--require-clean"], backend);
  assert.ok(journaled.cells >= 5, "one cell per crash step");
  assert.equal(journaled.failing_cells, 0, `journal crash matrix on ${backend}`);
  console.log(`${backend}: durable harnesses passed; today's crash matrix: ${crash.failing_cells}/${crash.cells} one-never cells ran send_email twice; journaled: none`);
}
console.log("durable harness checks passed");
