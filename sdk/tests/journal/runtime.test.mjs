import { strict as assert } from "node:assert";
import { test } from "node:test";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const worker = fileURLToPath(new URL("./worker.mjs", import.meta.url));
const backends = (process.env.FX_JOURNAL_BACKENDS ?? "native,wasm").split(",");
for (const backend of backends) assert.ok(["native", "wasm"].includes(backend), `invalid backend: ${backend}`);

function fixture(t, backend) {
  const directory = mkdtempSync(join(tmpdir(), "fx-journal-red-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const read = (name, fallback) => existsSync(join(directory, name)) ? JSON.parse(readFileSync(join(directory, name), "utf8")) : fallback;
  const run = (options = {}) => {
    const child = spawnSync(process.execPath, ["--experimental-wasm-jspi", worker], {
      input: JSON.stringify({ backend, directory, ...options }), encoding: "utf8", timeout: 20_000,
      // Do not pass real credentials to the fixture. The SDK receives only its
      // dummy key and a local deterministic fetch implementation.
      env: { PATH: process.env.PATH, HOME: directory, TMPDIR: process.env.TMPDIR ?? tmpdir() },
    });
    assert.ifError(child.error);
    assert.equal(child.signal, null, `unexpected process signal: ${child.stderr}`);
    assert.ok([0, 86].includes(child.status), `worker failed (${child.status}): ${child.stderr}`);
    assert.equal(child.stderr, "", "unexpected host stderr (not an acceptance failure)");
    const report = read("report.json");
    assert.ok(report, "worker failed to publish a report");
    assert.equal(report.stderr, "", "unexpected core stderr");
    if (options.cut) {
      assert.equal(report.cutReached, options.cut,
        `required boundary ${options.cut} never reached; observed journal entries=${JSON.stringify(report.entries)}, result=${JSON.stringify(report.result)}, errors=${JSON.stringify(report.errors)}`);
      assert.equal(child.status, 86, "cut used graceful shutdown instead of process death");
    } else assert.equal(child.status, 0);
    return report;
  };
  return {
    run, read,
    requests: () => read("requests.json", []),
    effects: () => read("effects.json", { invocations: [], effects: [], receipts: {}, jobs: [] }),
    entries: () => read("entries.json", []),
    write: (name, value) => writeFileSync(join(directory, name), JSON.stringify(value), { flush: true }),
  };
}
function entryBody(entry) {
  return JSON.parse(Buffer.from(entry.bytes, "base64").toString("utf8"));
}
function boundary(entry) {
  if (!entry) return undefined;
  return entry.kind === "model_step" && entryBody(entry).phase === "request" ? "model_request" : entry.kind;
}
function successful(report) {
  assert.deepEqual(report.errors, []);
  assert.equal(report.resultError, undefined, `turn rejected: ${report.resultError}`);
  assert.ok(report.result?.stopReason === "end_turn" || report.result?.stopReason === "stop", JSON.stringify(report));
}
function pendingTool(report) {
  const pending = report.initialStatus?.pendingTurn;
  assert.ok(pending, `restore lost pending turn: ${JSON.stringify(report.initialStatus)}`);
  assert.equal(typeof pending.awaiting, "object", "restore lost the selected tool boundary");
  return pending.awaiting.tool;
}

for (const backend of backends) {
  const check = (name, fn) => test(`${backend}: ${name}`, (t) => fn(fixture(t, backend)));

  check("control: real core completes fixture tool and model without a network", (f) => {
    successful(f.run({ exportCheckpoint: true }));
    assert.equal(f.effects().effects.length, 1);
    assert.equal(f.requests().length, 2);
  });

  check("J01 turn_start is durable before the first billed model request", (f) => {
    f.run({ cut: "provider-entered" });
    assert.deepEqual(f.requests()[0].durableKinds, ["turn_start", "model_step"], "model ran without both durable turn and request records");
    assert.deepEqual(f.requests()[0].durableBoundaries, ["turn_start", "model_request"]);
    const request = entryBody(f.entries()[1]);
    assert.equal(request.phase, "request");
    assert.equal(request.executionContext.recovery.outstanding_reservation, true);
    assert.equal("completion" in request, false);
    assert.equal("calls" in request, false);
    assert.equal("final" in request, false);
  });

  for (const kind of ["turn_start", "model_request", "model_step", "tool_result", "turn_end"]) {
    for (const phase of ["before", "after"]) {
      check(`J01 crash ${phase} ${kind} acknowledgement restores authoritative bytes`, (f) => {
        f.run({ cut: `${phase}:${kind}`, replay: "safe" });
        const saved = f.entries();
        assert.equal(boundary(saved.at(-1)) === kind, phase === "after");
        const counts = { requests: f.requests().length, effects: f.effects().effects.length };
        const restored = f.run({ action: "inspect", restore: true, replay: "safe" });
        assert.deepEqual(restored.errors, []);
        assert.equal(f.requests().length, counts.requests, "restore implicitly called the model");
        assert.equal(f.effects().effects.length, counts.effects, "restore implicitly executed a tool");
        assert.deepEqual(f.entries(), saved, "restore appended or retried a possibly committed entry");
        if (phase === "after" && kind === "turn_end") assert.equal(restored.initialStatus.idle, true);
        else if (saved.length) assert.equal(restored.initialStatus.idle, false);
        // Reconciliation, rather than an in-place retry, owns the next append.
        if (saved.length && saved.at(-1).kind !== "turn_end") {
          successful(f.run({ action: "resume", restore: true, replay: "safe" }));
          const seqs = f.entries().map((entry) => entry.seq);
          assert.deepEqual(seqs, seqs.map((_, index) => index + 1), "duplicate or missing sequence after recreation");
        }
      });
    }
  }

  check("J02 selected decision is durable before any tool effect", (f) => {
    const first = f.run({ cut: "before-effect" });
    assert.ok(first.atTool.durableKinds.includes("model_step"), "tool entered before its selected call was durable");
    assert.ok(first.atTool.durableBoundaries.includes("model_step"), "a request reservation is not a selected decision");
    assert.equal(f.effects().effects.length, 0);
    const pending = pendingTool(f.run({ action: "inspect", restore: true }));
    assert.equal(pending.name, "effect");
    assert.deepEqual(pending.input, { operation: "effect-a" });
    assert.equal(pending.callId, first.atTool.callId);
  });

  check("J02 crash before model_step commit reruns model, never an unrecorded tool", (f) => {
    f.run({ cut: "before:model_step", replay: "safe" });
    assert.equal(f.effects().invocations.length, 0);
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    assert.equal(f.effects().effects.length, 1);
    assert.equal(f.requests().length, 3, "unrecorded model decision must be obtained again");
  });

  check("J03 atomic effect and receipt survive death before tool_result", (f) => {
    f.run({ cut: "after-effect", replay: "safe" });
    assert.equal(f.effects().effects.length, 1, "fault did not happen after the effect");
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    assert.equal(f.effects().invocations.length, 2, "safe recovery must consult the original receipt");
    assert.equal(f.effects().effects.length, 1, "safe recovery repeated an effect");
    assert.equal(f.requests().length, 2, "recovery regenerated an already selected decision");
    const [original, recovered] = f.effects().invocations;
    assert.ok(original.callId, "tool never received a durable call identity");
    assert.equal(recovered.callId, original.callId);
    assert.equal(recovered.recovering, true);
  });

  check("J04 lost tool acknowledgement recovers its receipt without reapplying effect", (f) => {
    const first = f.run({ toolLostAck: true, replay: "safe" });
    assert.ok(first.resultError || first.result?.stopReason === "paused", "uncertain outcome was called successful");
    assert.equal(f.effects().effects.length, 1);
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    assert.equal(f.effects().effects.length, 1);
    assert.equal(f.effects().invocations.length, 2);
    assert.equal(f.requests().length, 2);
  });

  check("J05 selected safe tool with no committed effect executes on recovery", (f) => {
    f.run({ cut: "before-effect", replay: "safe" });
    assert.equal(f.effects().effects.length, 0);
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    assert.equal(f.effects().effects.length, 1);
    assert.equal(f.requests().length, 2, "selected call was regenerated instead of restored");
  });

  for (const batch of [false, true]) {
    check(`J06 default-blocked ${batch ? "batch" : "single call"} stays inspectable and abandonable`, (f) => {
      const first = f.run({ cut: "after-effect", batch });
      const inspected = f.run({ action: "inspect", restore: true, batch });
      const pending = pendingTool(inspected);
      assert.equal(pending.callId, first.atTool.callId);
      assert.equal(pending.replay, "blocked");
      const resumed = f.run({ action: "resume", restore: true, batch });
      assert.match(resumed.resultError ?? resumed.errors.join(" "), /RecoveryRequired/);
      assert.equal(f.effects().invocations.length, 1, "blocked recovery invoked A or B");
      assert.equal(f.requests().length, 1);
      const abandoned = f.run({ action: "abandon", restore: true, batch });
      assert.deepEqual(abandoned.errors, []);
      assert.equal(f.entries().at(-1).kind, "turn_end", "abandon did not durably retire pending work");
      assert.equal(f.effects().effects.length, 1, "abandon changed the external world");
    });
  }

  check("J07 durable final model_step needs only turn_end, not another model call", (f) => {
    f.run({ textOnly: true, cut: "before:turn_end" });
    assert.equal(f.entries().at(-1).kind, "model_step");
    assert.equal(boundary(f.entries().at(-1)), "model_step", "a reservation cannot substitute for durable final output");
    successful(f.run({ textOnly: true, action: "resume", restore: true }));
    assert.equal(f.requests().length, 1, "final response was billed again");
    assert.equal(f.entries().at(-1).kind, "turn_end");
  });

  check("J07 resolved result is already durable without a host checkpoint call", (f) => {
    const first = f.run({ textOnly: true });
    successful(first);
    assert.equal(first.resultDurableKinds.at(-1), "turn_end", "result resolved before durable completion");
    const restored = f.run({ action: "inspect", restore: true });
    assert.equal(restored.initialStatus.idle, true);
  });

  check("J01 lost append acknowledgement fences this owner rather than retrying blindly", (f) => {
    const first = f.run({ rejectEntry: "model_step", retryOnOwner: true, replay: "safe" });
    assert.ok(first.entries.some((entry) => entry.boundary === "model_step"), "kernel ignored the durable decision append callback");
    assert.equal(f.effects().effects.length, 0, "effects ran after an unacknowledged decision");
    assert.equal(first.afterRetry.requests, first.afterRetry.before.requests);
    assert.equal(first.afterRetry.entries, first.afterRetry.before.entries);
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
  });

  check("J01 unacknowledged model request fences the owner before provider I/O", (f) => {
    const first = f.run({ rejectEntry: "model_request", retryOnOwner: true, replay: "safe" });
    assert.ok(first.entries.some((entry) => entry.boundary === "model_request"));
    assert.equal(f.requests().length, 0, "provider ran before request acknowledgement");
    assert.equal(f.effects().invocations.length, 0);
    assert.equal(first.fencedStatusError.code, "PersistenceUncertain");
    assert.equal(first.afterRetry.requests, first.afterRetry.before.requests);
    assert.equal(first.afterRetry.entries, first.afterRetry.before.entries);
    const saved = f.entries();
    const inspected = f.run({ action: "inspect", restore: true, replay: "safe" });
    assert.deepEqual(inspected.errors, []);
    assert.equal(inspected.initialStatus.pendingTurn.awaiting, "model");
    assert.equal(f.requests().length, 0);
    assert.deepEqual(f.entries(), saved, "pure restore changed the request reservation");
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    assert.equal(f.requests().length, 2);
    assert.equal(f.effects().effects.length, 1);
  });

  check("J01 restored request preserves provider budget and authority before another call", (f) => {
    f.run({ cut: "provider-entered", replay: "safe" });
    const saved = f.entries();
    const original = entryBody(saved.at(-1));
    assert.equal(original.phase, "request");
    assert.equal(original.supersedesGenerationId, null);
    const inspected = f.run({ action: "inspect", restore: true, replay: "safe" });
    assert.deepEqual(inspected.errors, []);
    assert.deepEqual(f.entries(), saved);
    assert.equal(f.requests().length, 1, "inspection launched provider I/O");
    successful(f.run({ action: "resume", restore: true, replay: "safe" }));
    const reservations = f.entries().filter((entry) => boundary(entry) === "model_request").map(entryBody);
    const resumed = reservations[1];
    assert.equal(resumed.messageId, original.messageId);
    assert.notEqual(resumed.generationId, original.generationId);
    assert.equal(resumed.supersedesGenerationId, original.generationId);
    assert.deepEqual(resumed.executionContext.recovery.authority, original.executionContext.recovery.authority);
    assert.equal(resumed.executionContext.recovery.max_provider_attempts, original.executionContext.recovery.max_provider_attempts);
    assert.equal(resumed.executionContext.recovery.consumed_provider_attempts, original.executionContext.recovery.consumed_provider_attempts + 1);
    assert.equal(resumed.executionContext.recovery.outstanding_reservation, true);
    assert.equal(f.requests().length, 3);
    assert.equal(f.effects().effects.length, 1);
  });

  check("J08 mid-stream crash exposes a draft identity and resume uses a fresh generation", (f) => {
    const interrupted = f.run({ textOnly: true, cut: "draft" });
    const draft = interrupted.events.find((event) => event.type === "text_delta");
    assert.ok(draft?.key?.turnId && draft.key.messageId && draft.key.generationId,
      "streamed output lacks the identity a host needs to delete only the interrupted draft");
    const restored = f.run({ textOnly: true, restore: true, action: "resume" });
    successful(restored);
    const replacement = restored.events.find((event) => event.type === "text_delta");
    assert.ok(replacement?.key?.generationId);
    assert.notEqual(replacement.key.generationId, draft.key.generationId);
    assert.equal(replacement.key.turnId, draft.key.turnId);
    assert.ok(!restored.events.some((event) => event.delta?.includes("Uncommitted prefix.")));
  });

  check("J10 checkpoint and pruning retain request deduplication", (f) => {
    successful(f.run({ textOnly: true, exportCheckpoint: true }));
    const entries = f.entries();
    if (entries.length) {
      assert.equal(entries.at(-1).kind, "checkpoint");
      f.write("entries.json", [entries.at(-1)]);
    }
    const before = f.requests().length;
    successful(f.run({ textOnly: true, restore: true }));
    assert.equal(f.requests().length, before, "pre-checkpoint requestId executed again after restore/prune");
  });

  check("J11 completed requestId replays recorded text without a model request", (f) => {
    const original = f.run({ textOnly: true, exportCheckpoint: true });
    successful(original);
    const before = f.requests().length;
    const replayed = f.run({ textOnly: true, restore: true });
    successful(replayed);
    assert.equal(f.requests().length, before, "duplicate request called the provider again");
    const text = (report) => report.events.filter((e) => e.type === "text_delta").map((e) => e.delta).join("");
    assert.equal(text(replayed), text(original), "semantic replay lost the recorded answer");
  });

  check("J11 reused requestId with different input rejects without execution", (f) => {
    successful(f.run({ textOnly: true, exportCheckpoint: true }));
    const before = f.requests().length;
    const conflict = f.run({ textOnly: true, restore: true, input: "Different request with the same ID" });
    assert.match(conflict.resultError ?? conflict.errors.join(" "), /RequestConflict/);
    assert.equal(f.requests().length, before);
  });

  check("J12 tool context carries recorded request, turn, and call identities", (f) => {
    const first = f.run({ cut: "before-effect", replay: "safe" });
    assert.equal(first.atTool.requestId, "request-1");
    assert.equal(typeof first.atTool.turnId, "string");
    assert.equal(typeof first.atTool.callId, "string");
    const one = f.run({ action: "inspect", restore: true, replay: "safe" });
    const two = f.run({ action: "inspect", restore: true, replay: "safe" });
    assert.deepEqual(two.initialStatus, one.initialStatus, "pure replay changed execution identities");
    assert.equal(pendingTool(one).callId, first.atTool.callId);
  });

  for (const replay of ["safe", "blocked"]) {
    check(`J13 ${replay} deployment outlives its owner without a duplicate job`, (f) => {
      f.run({ cut: "after-effect", deployment: true, replay });
      const jobs = f.read("provider.json");
      assert.equal(jobs.length, 1);
      assert.deepEqual(f.effects().receipts, {}, "cut must precede the local deployment receipt");
      jobs[0].state = "finished"; // external provider progresses with no agent alive
      f.write("provider.json", jobs);
      const restored = f.run({ action: "inspect", restore: true, deployment: true, replay });
      assert.equal(pendingTool(restored).input.operation, "deploy");
      if (replay === "safe") successful(f.run({ action: "resume", restore: true, deployment: true, replay }));
      else {
        const blocked = f.run({ action: "resume", restore: true, deployment: true, replay });
        assert.match(blocked.resultError ?? blocked.errors.join(" "), /RecoveryRequired/);
        assert.deepEqual(f.run({ action: "abandon", restore: true, deployment: true, replay }).errors, []);
      }
      assert.equal(f.read("provider.json").length, 1);
      assert.equal(f.read("provider.json")[0].state, "finished", "recovery cancelled the independent job");
      assert.equal(f.effects().effects.length, 1);
      if (replay === "safe") assert.ok(f.requests().at(-1).body.includes("receipt:deploy:job-1"), "recovery lost the original provider job id");
    });
  }

  check("journal validation rejects malformed authoritative storage before effects", (f) => {
    f.write("entries.json", [{ seq: 7, kind: "model_step", hash: "invalid", bytes: "bm90LWEtam91cm5hbA==" }]);
    const restored = f.run({ action: "inspect", restore: true });
    assert.ok(restored.errors.length, "malformed journal was silently ignored");
    assert.equal(f.requests().length, 0);
    assert.equal(f.effects().invocations.length, 0);
  });
}
