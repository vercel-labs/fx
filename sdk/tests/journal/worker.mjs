// Isolated real-libfx owner. process.exit(86) is an injected process death, not
// close()/cancel(): no cleanup callback can manufacture a recovery checkpoint.
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { strict as assert } from "node:assert";
import { createFxAgent } from "../../node.js";

const spec = JSON.parse(readFileSync(0, "utf8"));
const path = (name) => join(spec.directory, name);
const read = (name, fallback) => existsSync(path(name)) ? JSON.parse(readFileSync(path(name), "utf8")) : fallback;
const save = (name, value) => {
  writeFileSync(path(`${name}.next`), JSON.stringify(value), { flush: true });
  renameSync(path(`${name}.next`), path(name));
};
// Files model durable host state at explicit cut points, not a power-loss or
// filesystem qualification. Effects + receipts share one atomic replacement.
let entries = read("entries.json", []);
let effects = read("effects.json", { invocations: [], receipts: {}, effects: [], jobs: [] });
let requests = read("requests.json", []);
const report = { events: [], entries: [], errors: [], cutReached: false, stderr: "" };
const record = () => save("report.json", report);
const crash = (point) => {
  report.cutReached = point;
  record();
  process.exit(86);
};
const encodeEntry = (entry) => ({ ...entry, bytes: Buffer.from(entry.bytes).toString("base64") });
const decodeEntry = (entry) => ({ ...entry, bytes: new Uint8Array(Buffer.from(entry.bytes, "base64")) });
const entryBody = (entry) => JSON.parse(new TextDecoder().decode(entry.bytes));
const boundary = (entry) => entry.kind === "model_step" && entryBody(entry).phase === "request" ? "model_request" : entry.kind;
const durableBoundaries = () => entries.map((entry) => boundary(decodeEntry(entry)));
let agent;
let suspension;
const persistEntry = async (entry) => {
  const encoded = encodeEntry(entry);
  const point = boundary(entry);
  report.entries.push({ kind: entry.kind, seq: entry.seq, phase: entryBody(entry).phase ?? null, boundary: point });
  if (spec.cut === `before:${point}`) crash(spec.cut);
  const duplicate = entries.find((saved) => saved.seq === entry.seq);
  if (duplicate) {
    if (JSON.stringify(duplicate) !== JSON.stringify(encoded)) throw new Error("JournalConflict");
  } else {
    const expected = entries.length ? entries.at(-1).seq + 1 : 1;
    if (entry.seq !== expected) throw new Error(`JournalConflict: expected ${expected}, got ${entry.seq}`);
    entries.push(encoded);
    save("entries.json", entries);
  }
  if (spec.cut === `after:${point}`) crash(spec.cut);
  if (spec.rejectEntry === point) throw new Error("PersistenceUncertain: acknowledgement lost after commit");
};
const options = {
  backend: spec.backend,
  nativeAddon: new URL("../../../zig-out/lib/libfx.node", import.meta.url),
  ...(spec.backend === "wasm" ? { wasm: readFileSync(new URL("../../../zig-out/bin/fx-core.wasm", import.meta.url)) } : {}),
  apiKey: "fixture-key", model: "journal/fixture", instructions: "Use only the deterministic fixture tools.",
  journal: entries.map(decodeEntry),
  onEntry: persistEntry,
  stderr(chunk) { report.stderr += new TextDecoder().decode(chunk); },
  async fetch(_url, init) {
    if (init.method === "GET") return Response.json({ object: "list", data: [] });
    const body = new TextDecoder().decode(init.body);
    requests.push({ body, durableKinds: entries.map((e) => e.kind), durableBoundaries: durableBoundaries() });
    save("requests.json", requests);
    if (spec.cut === "provider-entered") crash(spec.cut);
    const hasResult = body.includes("receipt:effect-a") || body.includes("receipt:deploy");
    let events;
    if (spec.textOnly || hasResult) {
      events = [
        { type: "text-delta", delta: "Final recorded answer." },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ];
    } else {
      events = (spec.batch ? ["effect-a", "effect-b"] : [spec.deployment ? "deploy" : "effect-a"]).map((operation) => ({
        type: "tool-call", toolCallId: `provider-${operation}`, toolName: "effect", input: { operation },
      }));
      events.push({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
    }
    if (spec.cut === "draft") {
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ type: "text-delta", delta: "Uncommitted prefix." })}\n\n`));
          // Held open: the consumer-triggered process death is necessarily
          // before final model output, not an event-drain scheduling race.
        },
      }), { headers: { "content-type": "text/event-stream" } });
    }
    return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
      headers: { "content-type": "text/event-stream" },
    });
  },
  tools: [{
    name: "effect", description: "Deterministic atomic effect-and-receipt fixture",
    inputSchema: { type: "object", properties: { operation: { type: "string" } }, required: ["operation"] },
    ...(spec.replay ? { replay: spec.replay } : {}),
    async execute(input, context) {
      const { operation } = input;
      const { callId, turnId, requestId, recovering } = context;
      if (![callId, turnId, requestId].every((id) => typeof id === "string" && id.length)) {
        throw new Error("Missing durable tool identity");
      }
      const inputHash = createHash("sha256").update(JSON.stringify(input)).digest("hex");
      const receipt = effects.receipts[callId];
      if (receipt && (receipt.name !== "effect" || receipt.inputHash !== inputHash)) {
        throw new Error("JournalConflict: receipt tool or input changed");
      }
      effects.invocations.push({ operation, callId, turnId, requestId, recovering });
      save("effects.json", effects);
      report.atTool = { operation, callId, turnId, requestId, recovering, durableKinds: entries.map((e) => e.kind), durableBoundaries: durableBoundaries() };
      if (spec.cut === "before-effect") crash(spec.cut);
      if (receipt) return receipt.outcome;
      let outcome = `receipt:${operation}`;
      if (operation === "deploy") {
        // The provider is independent of the local receipt transaction. A job
        // can finish after this process dies, before ANY local result exists.
        const jobs = read("provider.json", []);
        let job = jobs.find((candidate) => candidate.callId === callId);
        if (job && (job.name !== "effect" || job.inputHash !== inputHash)) {
          throw new Error("JournalConflict: provider job tool or input changed");
        }
        if (!job) {
          job = { id: `job-${jobs.length + 1}`, callId, name: "effect", inputHash, state: "running" };
          jobs.push(job);
          save("provider.json", jobs);
          effects.effects.push({ operation, callId });
          save("effects.json", effects);
        }
        if (spec.cut === "after-effect") crash(spec.cut);
        outcome = `receipt:deploy:${job.id}`;
        effects.receipts[callId] = { name: "effect", inputHash, outcome };
        save("effects.json", effects);
      } else {
        effects.effects.push({ operation, callId });
        effects.receipts[callId] = { name: "effect", inputHash, outcome };
        save("effects.json", effects);
        if (spec.cut === "after-effect") crash(spec.cut);
      }
      if (spec.toolLostAck) throw new Error("PersistenceUncertain: effect and receipt committed, acknowledgement lost");
      if (spec.suspendInTool) {
        suspension = agent.suspend();
        void suspension.catch(() => {});
      }
      return outcome;
    },
  }],
};
const observe = async (turn) => {
  const drain = (async () => {
    try {
      for await (const event of turn) {
        report.events.push(event);
        if (spec.cut === "draft" && event.type === "text_delta") crash(spec.cut);
      }
    } catch (error) { report.iteratorError = error.message; }
  })();
  try {
    report.result = await turn.result;
    report.resultDurableKinds = entries.map((entry) => entry.kind);
  } catch (error) { report.resultError = error.message; }
  await drain;
  if (suspension) await suspension.catch((error) => { report.suspensionError = error.message; });
};
try {
  agent = await createFxAgent(options);
  report.initialStatus = await agent.status();
  if (spec.action === "inspect") {
    // Restore alone must have no effects.
  } else if (spec.action === "abandon") {
    await agent.abandon();
  } else if (spec.action === "resume") {
    await observe(agent.resume());
  } else {
    await observe(agent.prompt(spec.input ?? "Perform the effect and finish.", { requestId: spec.requestId ?? "request-1" }));
  }
  if (spec.retryOnOwner) {
    const before = { requests: requests.length, invocations: effects.invocations.length, entries: entries.length };
    try { await observe(agent.prompt("Must not execute after uncertainty", { requestId: "request-2" })); }
    catch (error) { report.retryError = error.message; }
    report.afterRetry = { before, requests: requests.length, invocations: effects.invocations.length, entries: entries.length };
  }
  try {
    report.status = await agent.status();
  } catch (error) {
    if (!spec.retryOnOwner) throw error;
    report.fencedStatusError = { name: error.name, code: error.code, message: error.message };
  }
  if (spec.exportCheckpoint) {
    try {
      const checkpoint = await agent.checkpoint();
      if (checkpoint?.kind !== "checkpoint" || !(checkpoint.bytes instanceof Uint8Array)) {
        throw new TypeError("journal checkpoint() did not return an entry");
      }
      report.exportedCheckpoint = encodeEntry(checkpoint);
    } catch (error) { report.checkpointError = error.message; }
  }

} catch (error) {
  report.errors.push(error.message);
} finally {
  await agent?.close().catch((error) => report.errors.push(`close: ${error.message}`));
  record();
}

// The uncertainty witness must reach both probes and retain the typed status
// rejection; an unrelated failure cannot silently satisfy the fencing test.
if (spec.retryOnOwner) {
  assert.equal(report.fencedStatusError?.code, "PersistenceUncertain", JSON.stringify(report.fencedStatusError));
  assert.ok(report.afterRetry, "fenced owner retry probe never ran");
}
