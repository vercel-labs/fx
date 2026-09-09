// Small deterministic contract simulations for adapter-owned rules. These are
// not production adapters, and a passing model is NOT a passing libfx witness.
// Each counterexample changes one rule while holding the schedule fixed.
import { strict as assert } from "node:assert";
import { test } from "node:test";

function project(calls, results, pendingTool) {
  const firstMissing = calls.findIndex((call) => !results.has(call));
  return calls.map((call, index) => ({
    call,
    status: results.has(call) ? "complete" : pendingTool == null ? "pending" : index === firstMissing ? "unknown" : "skipped",
  }));
}
function validateProjection(rows, effects, results) {
  for (const { call, status } of rows) {
    assert.ok(status !== "complete" || results.has(call), "CompleteImpliesResult");
    assert.ok(status !== "skipped" || !effects.has(call), "SkippedNeverRan");
  }
}

test("simulation J06 abandonment preserves unknown A and skipped B, including single-call case", () => {
  for (const calls of [["A"], ["A", "B"]]) {
    const rows = project(calls, new Set(), "A");
    assert.equal(rows[0].status, "unknown");
    if (calls.length > 1) assert.equal(rows[1].status, "skipped");
    validateProjection(rows, new Set(["A"]), new Set());
    for (const status of ["complete", "skipped"]) {
      const broken = structuredClone(rows);
      broken[0].status = status;
      assert.throws(() => validateProjection(broken, new Set(["A"]), new Set()),
        status === "complete" ? /CompleteImpliesResult/ : /SkippedNeverRan/);
    }
  }
});

// Storage and publication must adopt one candidate together. Queued flushes
// select live drafts when they execute, not when they were queued.
function draftSchedule({ staleFlush = false, deleteOnlyInMemory = false } = {}) {
  let disk = { committed: [], drafts: { old: "completed text", active: "unfinished prefix" } };
  let live = structuredClone(disk);
  const queuedBeforeCommit = structuredClone(live.drafts);
  const previousSnapshot = structuredClone(live);
  // Model step commits 'old' and deletes exactly its completed draft identity.
  disk = { committed: ["completed text"], drafts: { active: disk.drafts.active } };
  live = structuredClone(disk);
  assert.equal(previousSnapshot.committed.length, 0, "preview mutated an earlier snapshot");
  if (staleFlush) disk.drafts = queuedBeforeCommit;
  assert.ok(!("old" in disk.drafts), "DraftNotLanded");
  // Crash, recreate using durable host state; kernel receives no draft table.
  live = structuredClone(disk);
  const frames = [];
  for (const key of Object.keys(live.drafts)) {
    delete live.drafts[key];
    if (!deleteOnlyInMemory) delete disk.drafts[key];
    frames.push({ type: "draft_discarded", key });
  }
  frames.push({ type: "resume" });
  // Crash AGAIN before replacement output. Old drafts must remain absent.
  live = structuredClone(disk);
  assert.deepEqual(live.drafts, {}, "NoStaleDraft");
  assert.deepEqual(live.committed, ["completed text"], "discard deleted committed text");
  assert.deepEqual(frames, [{ type: "draft_discarded", key: "active" }, { type: "resume" }]);
}

test("simulation J08 queued flush, commit, crash, delete, second crash never revives drafts", () => draftSchedule());
test("simulation counterexample stale queued draft flush revives committed output", () => {
  assert.throws(() => draftSchedule({ staleFlush: true }), /DraftNotLanded/);
});
test("simulation counterexample volatile-only draft deletion fails on a second crash", () => {
  assert.throws(() => draftSchedule({ deleteOnlyInMemory: true }), /NoStaleDraft/);
});

function admit({ known, id, input, issuedAt, now, window, skew }) {
  // Known IDs are checked before age, including retries of checkpointed turns.
  if (known.has(id)) {
    assert.equal(known.get(id).input, input, "RequestConflict");
    return "replay";
  }
  if (issuedAt < now - window) return 410;
  if (issuedAt > now + skew) return 400;
  return "new";
}
function prune(rows, now, retention, countLimit, countOnly = false) {
  return rows.filter((row, index) => (!countOnly && row.at >= now - retention) || index >= rows.length - countLimit);
}

test("simulation J09 admission checks known requests first and rejects stale unknown retries", () => {
  const known = new Map([["old", { input: "original" }]]);
  const options = { known, now: 1000, window: 100, skew: 10, input: "original", issuedAt: 0 };
  assert.equal(admit({ ...options, id: "old" }), "replay");
  assert.throws(() => admit({ ...options, id: "old", input: "changed" }), /RequestConflict/);
  assert.equal(admit({ ...options, id: "unknown" }), 410);
  assert.equal(admit({ ...options, id: "fresh", issuedAt: 950 }), "new");
  assert.equal(admit({ ...options, id: "future", issuedAt: 1011 }), 400);
});

test("simulation J09 a busy session cannot let a count bound erase its admission window", () => {
  const rows = Array.from({ length: 100 }, (_, index) => ({ id: `request-${index}`, at: 950 + index / 10 }));
  const retained = prune(rows, 1000, 110, 3);
  assert.equal(retained.length, 100);
  const broken = prune(rows, 1000, 110, 3, true);
  assert.throws(() => assert.ok(broken.some((row) => row.id === "request-0"), "Retention"), /Retention/);
});

function checkpointRoundTrip({ dropDedup = false, dropTranscript = false } = {}) {
  const before = {
    transcript: [{ id: "u1", text: "original" }, { id: "a1", text: "recorded answer" }],
    requests: [["request-1", { input: "original", turnId: "turn-1", result: "recorded answer" }]],
  };
  const bytes = JSON.stringify({
    transcript: dropTranscript ? [] : before.transcript,
    requests: dropDedup ? [] : before.requests,
  });
  // Covered records have been pruned; no fallback source exists.
  const restored = JSON.parse(bytes);
  assert.deepEqual(restored.transcript, before.transcript, "TranscriptRetention");
  assert.equal(admit({ known: new Map(restored.requests), id: "request-1", input: "original", issuedAt: 950, now: 1000, window: 100, skew: 10 }), "replay", "DedupSafe");
  assert.equal(new Map(restored.requests).get("request-1").result, "recorded answer");
}

test("simulation J10 J11 checkpoint-only restoration keeps transcript and recorded outcome", () => checkpointRoundTrip());
test("simulation counterexample checkpoint without dedup executes an admitted retry", () => {
  assert.throws(() => checkpointRoundTrip({ dropDedup: true }), /DedupSafe/);
});
test("simulation counterexample checkpoint without transcript loses visible history", () => {
  assert.throws(() => checkpointRoundTrip({ dropTranscript: true }), /TranscriptRetention/);
});

test("simulation J13 local receipt absence is not provider job absence", () => {
  const providerJobs = new Map();
  const localReceipts = new Map();
  let issued = 0;
  const submit = (key) => {
    if (!providerJobs.has(key)) providerJobs.set(key, { id: `job-${++issued}`, state: "running" });
    return providerJobs.get(key);
  };
  const original = submit("call-1");
  // The response is lost, the owner dies, and the provider completes the job.
  assert.equal(localReceipts.has("call-1"), false);
  original.state = "finished";
  const recovered = submit("call-1");
  assert.equal(recovered.id, "job-1");
  assert.equal(issued, 1);
  // Abandonment neither cancels nor globally locks deployment for future turns.
  assert.equal(original.state, "finished");
  assert.equal(submit("call-2").id, "job-2");
  assert.equal(issued, 2);
});
