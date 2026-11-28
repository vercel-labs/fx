#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxTerminal, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/tests/test-term-reload-mid-turn.mjs");
  process.exit(2);
}

const wasm = await readFile(wasmPath);
const encoded = new TextEncoder();
const decoder = new TextDecoder();
const PROMPT = "RELOAD_PROMPT_MARKER answer briefly";
const MARKER = "RELOAD_PROMPT_MARKER";
const runtimes = [];

function sseReply(text) {
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode(`data: {"type":"text-delta","id":"answer","delta":${JSON.stringify(text)}}\n\n`));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
}

function requestText(body) {
  return typeof body === "string" ? body : body ? decoder.decode(body) : "";
}

// A host store with opaque bytes and optimistic revisions, as sdk/AGENTS.md requires.
function createStore(name, initial = new Map()) {
  const records = new Map();
  for (const [id, record] of initial) {
    records.set(id, { bytes: record.bytes.slice(), revision: record.revision, updatedAtMs: record.updatedAtMs });
  }
  let commits = 0;
  let serial = 0;
  return {
    get commits() {
      return commits;
    },
    load(id) {
      const record = records.get(id);
      return record ? { bytes: record.bytes.slice(), revision: record.revision } : null;
    },
    commit(id, bytes, expectedRevision) {
      const current = records.get(id);
      if (current?.revision !== expectedRevision) {
        const error = new Error("session revision conflict");
        error.code = "FX_SESSION_REVISION_CONFLICT";
        throw error;
      }
      const revision = `${name}-${++serial}`;
      records.set(id, { bytes: bytes.slice(), revision, updatedAtMs: Date.now() });
      commits += 1;
      return { revision };
    },
    list() {
      return [...records.entries()].map(([id, record]) => ({ id, updatedAtMs: record.updatedAtMs }));
    },
    remove(id) {
      records.delete(id);
    },
    snapshot() {
      return new Map([...records].map(([id, record]) => [id, { bytes: record.bytes.slice(), revision: record.revision, updatedAtMs: record.updatedAtMs }]));
    },
  };
}

function createTerminalCapture() {
  let text = "";
  return {
    terminal: {
      cols: 80,
      rows: 24,
      write(value) {
        const bytes = value instanceof Uint8Array ? value : encoded.encode(value);
        text += decoder.decode(bytes, { stream: true });
      },
      async drain() {},
      onData() { return () => {}; },
      onResize() { return () => {}; },
    },
    text() {
      return text;
    },
  };
}

async function waitFor(predicate, label, diagnostics = () => "") {
  const deadline = performance.now() + 10000;
  while (!predicate()) {
    if (performance.now() >= deadline) {
      throw new Error(`timed out waiting for ${label}: ${diagnostics()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function expectCount(actual, want, what) {
  if (actual !== want) throw new Error(`${what}: ${actual}, want ${want}`);
}

async function start(store, args, fetch, options = {}) {
  const capture = createTerminalCapture();
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    args,
    terminal: capture.terminal,
    env: { AI_GATEWAY_API_KEY: "reload-mid-turn-test-key", FX_THEME: "dark" },
    fetch,
    sessionStore: store,
    ...options,
  });
  runtimes.push(runtime);
  await waitFor(
    () => capture.text().includes(args.length ? "session resumed" : "Run /help for commands"),
    "fx-term startup",
    () => `output=${JSON.stringify(capture.text().slice(-1000))}`,
  );
  return { capture, runtime };
}

function reload(runtime) {
  runtime.abort();
}

// Answers every request with `reply`, except the one a barrier sent. That one
// records how many requests came before it and the store's commit count when
// it arrived: the save before the request has already been made by then.
function recordingFetch(store, reply) {
  const recorded = { bodies: [], pending: null, barrier: null };
  recorded.fetch = async (_input, init) => {
    const before = recorded.bodies.length;
    recorded.bodies.push(requestText(init?.body));
    if (recorded.pending === null) return sseReply(reply);
    const label = recorded.pending;
    recorded.pending = null;
    recorded.barrier = { label, before, commits: store.commits };
    return sseReply(`${label}_REPLY`);
  };
  return recorded;
}

// Sends a follow-up prompt and waits for its request, its reply, and the
// commit that ends its turn. Anything that would have been sent earlier is
// already counted in the result, so no timer is needed to prove absence.
async function sendBarrier(runtime, capture, recorded, store, label, commitsAfterReply) {
  recorded.pending = label;
  runtime.write(`BARRIER_${label} answer briefly\r`);
  const output = () => JSON.stringify(capture.text().slice(-1000));
  await waitFor(() => recorded.barrier?.label === label, `the ${label} request`, () => `requests=${recorded.bodies.length}, output=${output()}`);
  await waitFor(
    () => capture.text().includes(`${label}_REPLY`) && store.commits === commitsAfterReply,
    `the ${label} reply and its commit`,
    () => `commits=${store.commits}, output=${output()}`,
  );
  return recorded.barrier;
}

// The model request never answers, so the page reloads while the turn is still running.
async function heldScenario() {
  const store1 = createStore("held-1");
  const firstRequests = [];
  let commitsAtFetch = -1;
  const heldFetch = (_input, init) => {
    firstRequests.push(requestText(init?.body));
    commitsAtFetch = store1.commits;
    return new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
    });
  };
  const first = await start(store1, [], heldFetch);
  first.runtime.write(`${PROMPT}\r`);
  await waitFor(
    () => firstRequests.length === 1,
    "the first model request",
    () => `commits=${store1.commits}, output=${JSON.stringify(first.capture.text().slice(-1000))}`,
  );
  // The save before the request is the turn's only commit until the turn ends.
  expectCount(commitsAtFetch, 1, "commits before the model request");
  const snapshot = store1.snapshot();
  reload(first.runtime);

  const store2 = createStore("held-2", snapshot);
  const resumed = recordingFetch(store2, "RESUMED_REPLY");
  const second = await start(store2, ["-c"], resumed.fetch);
  if (!second.capture.text().includes(MARKER)) {
    throw new Error(`the reloaded terminal did not show the prompt: ${JSON.stringify(second.capture.text().slice(-1000))}`);
  }
  // The resumed turn: its save before the resent request, then its end commit.
  await waitFor(
    () => second.capture.text().includes("RESUMED_REPLY") && store2.commits === 2,
    "the resumed reply and its end commit",
    () => `commits=${store2.commits}, output=${JSON.stringify(second.capture.text().slice(-1000))}`,
  );
  const barrier2 = await sendBarrier(second.runtime, second.capture, resumed, store2, "HELD_TWO", 4);
  // Only the resent request came before the barrier, and the resumed turn's two commits plus the barrier's save make three.
  expectCount(barrier2.before, 1, "requests before the follow-up prompt");
  expectCount(barrier2.commits, 3, "commits when the follow-up prompt's request arrived");
  if (!resumed.bodies[0].includes(MARKER) || !resumed.bodies[0].includes("<session_resumed>")) {
    throw new Error("the resumed request lacks the prompt or the session_resumed note");
  }
  reload(second.runtime);

  const store3 = createStore("held-3", store2.snapshot());
  const last = recordingFetch(store3, "UNEXPECTED_EXTRA_REQUEST");
  const third = await start(store3, ["-c"], last.fetch);
  await waitFor(
    () => third.capture.text().includes(MARKER) && third.capture.text().includes("HELD_TWO_REPLY"),
    "the finished turns after the last reload",
    () => `output=${JSON.stringify(third.capture.text().slice(-1000))}`,
  );
  const barrier3 = await sendBarrier(third.runtime, third.capture, last, store3, "HELD_THREE", 2);
  // Nothing was sent when the last reload started, so the barrier's request is the first one.
  expectCount(barrier3.before, 0, "requests sent after the last reload before the follow-up prompt");
  expectCount(barrier3.commits, 1, "commits when the last reload's follow-up request arrived");
  reload(third.runtime);
  return { commitsAtFetch, barrier2, barrier3 };
}

// The control: the page reloads after the turn finished, so nothing resends.
async function doneScenario() {
  const store1 = createStore("done-1");
  const first = recordingFetch(store1, "FIRST_REPLY");
  const started = await start(store1, [], first.fetch);
  started.runtime.write(`${PROMPT}\r`);
  await waitFor(
    () => started.capture.text().includes("FIRST_REPLY") && store1.commits === 2,
    "the finished turn's commits",
    () => `commits=${store1.commits}, output=${JSON.stringify(started.capture.text().slice(-1000))}`,
  );
  // The turn's one request came before this barrier; its two commits and the barrier's save make three.
  const barrier1 = await sendBarrier(started.runtime, started.capture, first, store1, "DONE_ONE", 4);
  expectCount(barrier1.before, 1, "requests before the follow-up prompt of the finished turn");
  expectCount(barrier1.commits, 3, "commits when the follow-up prompt's request arrived");
  const snapshot = store1.snapshot();
  reload(started.runtime);

  const store2 = createStore("done-2", snapshot);
  const reloaded = recordingFetch(store2, "UNEXPECTED_EXTRA_REQUEST");
  const second = await start(store2, ["-c"], reloaded.fetch);
  if (!second.capture.text().includes(MARKER)) {
    throw new Error(`the control did not show the finished prompt: ${JSON.stringify(second.capture.text().slice(-1000))}`);
  }
  const barrier2 = await sendBarrier(second.runtime, second.capture, reloaded, store2, "DONE_TWO", 2);
  // The reload sent nothing before the barrier's request.
  expectCount(barrier2.before, 0, "requests sent by the reload before the follow-up prompt");
  expectCount(barrier2.commits, 1, "commits when the control's follow-up request arrived");
  reload(second.runtime);
  return { barrier1, barrier2 };
}

const CUT_MODEL = "test/cut-model";
const CUT_PROMPT = "CUT_PROMPT_MARKER read the notes";
// The first step's output, which the compaction inside the turn summarizes.
const FOLDED = "FOLDED_OUTPUT_5c1e";
const HANDOFF = "Facts:\nF1: CUT_HANDOFF_3e7a: the user asked to read the notes.";

function cutCatalog() {
  return Response.json({
    object: "list",
    data: [{ id: CUT_MODEL, type: "language", released: 1, tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }],
  });
}

function shellCall(id, command) {
  const events = [
    { type: "tool-call", toolCallId: id, toolName: "shell", input: { action: "run", command } },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ];
  return new Response(`${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`, {
    headers: { "content-type": "text/event-stream" },
  });
}

// A summary request has no tools, or keeps them for the cache with fx's note
// that the request is its own.
function isSummaryRequest(text, body) {
  return (body.toolChoice?.type === "none" && body.tools?.length === 0) ||
    text.includes("This request comes from fx, not from the user") ||
    text.includes("Write the compaction notes");
}

function cutOptions() {
  const config = new Map([["model", CUT_MODEL], ["mode", "auto"]]);
  return {
    configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
    workspace: {
      info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
      permission: "allow-sandboxed",
      exec({ command }) {
        if (command !== "print-notes") throw new Error(`unexpected workspace command: ${command}`);
        // Large enough that the compaction keeps none of it.
        return { stdout: `${FOLDED}\n${"a b c d e f g h i j k l m n o p\n".repeat(600)}`, stderr: "", exitCode: 0 };
      },
    },
  };
}

// A compaction inside the turn folds its first step into a summary, and the
// page reloads while the request after the compaction is in flight. The
// reload sends that request again from the saved checkpoint, which must hold
// what fx kept after the cut: the folded step must not reach the model again.
async function cutScenario() {
  const store1 = createStore("cut-1");
  const turnRequests = [];
  let summaries = 0;
  let refused = false;
  let commitsAtHeld = -1;
  const firstFetch = (_input, init = {}) => {
    if ((init.method ?? "GET") === "GET") return cutCatalog();
    const text = requestText(init.body);
    const body = JSON.parse(text);
    if (isSummaryRequest(text, body)) {
      summaries += 1;
      return sseReply(HANDOFF);
    }
    if (!text.includes("CUT_PROMPT_MARKER")) return sseReply("SEED_DONE_REPLY");
    turnRequests.push(text);
    if (turnRequests.length === 1) return shellCall("fold-a", "print-notes");
    if (!refused) {
      refused = true;
      return Response.json({ error: {
        type: "invalid_request_error",
        code: "context_length_exceeded",
        message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
      } }, { status: 400 });
    }
    commitsAtHeld = store1.commits;
    return new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
    });
  };
  const first = await start(store1, [], firstFetch, cutOptions());
  first.runtime.write("Seed one turn.\r");
  await waitFor(() => first.capture.text().includes("SEED_DONE_REPLY"), "the seed reply");
  first.runtime.write(`${CUT_PROMPT}\r`);
  const output = () => JSON.stringify(first.capture.text().slice(-1500));
  await waitFor(() => turnRequests.length === 3, "the request after the compaction", () => `requests=${turnRequests.length}, summaries=${summaries}, output=${output()}`);
  expectCount(summaries, 1, "summary requests");
  const live = turnRequests[2];
  if (live.includes(FOLDED) || !turnRequests[1].includes(FOLDED)) {
    throw new Error("the compaction did not fold the first step out of the live request");
  }
  const snapshot = store1.snapshot();
  reload(first.runtime);

  const store2 = createStore("cut-2", snapshot);
  const resent = [];
  const secondFetch = (_input, init = {}) => {
    if ((init.method ?? "GET") === "GET") return cutCatalog();
    const text = requestText(init.body);
    resent.push(text);
    return sseReply("CUT_RESUMED_REPLY");
  };
  const second = await start(store2, ["-c"], secondFetch, cutOptions());
  await waitFor(
    () => second.capture.text().includes("CUT_RESUMED_REPLY"),
    "the resent request's reply",
    () => `requests=${resent.length}, output=${JSON.stringify(second.capture.text().slice(-1500))}`,
  );
  const request = resent[0];
  if (!request.includes("CUT_PROMPT_MARKER")) throw new Error("the resent request lacks the prompt");
  if (request.includes(FOLDED) || request.includes('"fold-a"')) {
    throw new Error("the resent request holds the step the compaction folded into its summary");
  }
  if (request.includes("CUT_HANDOFF_3e7a") !== live.includes("CUT_HANDOFF_3e7a")) {
    throw new Error(`the resent request and the live one disagree on the summary: live=${live.includes("CUT_HANDOFF_3e7a")}`);
  }
  reload(second.runtime);
  return { commitsAtHeld, summary: request.includes("CUT_HANDOFF_3e7a") };
}

try {
  const held = await heldScenario();
  const done = await doneScenario();
  const cut = await cutScenario();
  console.log(`term reload mid-turn passed: held_commits_at_fetch=1, held_resumed_requests_before_barrier=${held.barrier2.before}, held_barrier_commits=${held.barrier2.commits}, held_last_reload_requests_before_barrier=${held.barrier3.before}, done_requests_before_barrier=${done.barrier1.before}, done_barrier_commits=${done.barrier1.commits}, reload_after_finished_turn_requests_before_barrier=${done.barrier2.before}, cut_reload_resends_folded_step=false, cut_reload_keeps_summary=${cut.summary}`);
} finally {
  for (const runtime of runtimes) {
    try {
      runtime.abort();
    } catch (error) {
      console.error(`abort failed: ${error?.message ?? error}`);
    }
  }
}
