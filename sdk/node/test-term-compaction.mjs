#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const script = fileURLToPath(import.meta.url);
const wasmPath = resolve(process.argv[2] || fileURLToPath(new URL("../../zig-out/bin/fx-term.wasm", import.meta.url)));
if (!supportsJspi()) {
  console.error("JSPI is required: node --experimental-wasm-jspi sdk/node/test-term-compaction.mjs");
  process.exit(2);
}
const scenarios = ["success", "cancel-headers", "cancel-body", "auto-cancel-headers"];
const scenario = process.argv[3];
if (scenario) {
  assert(scenarios.includes(scenario));
  await runScenario(scenario);
} else {
  // A blocked cooperative loop must fail the test, not hang the entire SDK lane.
  for (const name of scenarios) {
    const child = spawn(process.execPath, ["--experimental-wasm-jspi", script, wasmPath, name], {
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", FX_SOUND: "0", FX_E2E_DISABLE_DOTENV: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    const result = await new Promise((resolveResult, reject) => {
      const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
      child.once("error", (error) => { clearTimeout(timer); reject(error); });
      child.once("exit", (code, signal) => { clearTimeout(timer); resolveResult({ code, signal }); });
    });
    assert.equal(result.code, 0, `${name}: ${JSON.stringify(result)}\n${stdout}\n${stderr}`);
    assert.equal(stderr, "", name);
    assert(stdout.includes(`term compaction ${name} passed`));
    process.stdout.write(stdout);
  }
}

function finalText(text) {
  return new Response([
    { type: "text-delta", id: "answer", delta: text },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } } },
  ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
}

function heldSummary(signal) {
  let resolveHeaders, rejectHeaders, controller;
  let headersReleased = false, bodyRead = false, aborted = false, finished = false;
  const response = new Promise((resolve, reject) => { resolveHeaders = resolve; rejectHeaders = reject; });
  const abort = () => {
    if (finished) return;
    aborted = true;
    finished = true;
    const error = new DOMException("synthetic request aborted", "AbortError");
    if (headersReleased) controller.error(error);
    else rejectHeaders(error);
  };
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  return {
    response,
    get bodyRead() { return bodyRead; },
    get aborted() { return aborted; },
    releaseHeaders() {
      assert(!headersReleased && !finished);
      headersReleased = true;
      resolveHeaders(new Response(new ReadableStream({
        start(value) { controller = value; },
        pull() { bodyRead = true; },
      }, { highWaterMark: 0 }), { headers: { "content-type": "text/event-stream" } }));
    },
    async releaseBody(text) {
      assert(headersReleased && bodyRead && !finished);
      finished = true;
      signal.removeEventListener("abort", abort);
      controller.enqueue(new Uint8Array(await finalText(text).arrayBuffer()));
      controller.close();
    },
  };
}

function grid(terminal) {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}

async function runScenario(name) {
  const { Terminal } = xtermHeadless;
  const wasm = await readFile(wasmPath);
  const head = "HOST_HISTORY_HEAD_73b4", tail = "HOST_HISTORY_TAIL_b149";
  let handoff;
  // Each ordinary reply is larger than the turns kept unchanged, so older turns
  // compact. Plain turns need no model call, but the first message sets a rule,
  // so compacting asks the model to file it. Three of them stay below the
  // automatic threshold, even with a cancelled attempt's followup.
  const automatic = name === "auto-cancel-headers";
  const seedTurns = automatic ? 1 : 3;
  const seedRule = "Always keep the history markers.";
  const seedReply = (turn) => `${turn === 1 ? head : `HOST_HISTORY_MIDDLE_${turn}`}\n${"history alpha beta gamma delta sample line\n".repeat(automatic ? 18_000 : 1_800)}HOST_SEED_DONE_${turn}${turn === seedTurns ? `\n${tail}` : ""}`;
  const activity = /Compacting \((?:\d+h)?(?:\d+m)?\d+s\)/;
  const forbidden = /Compacting|compaction|Context compacted|No context to compact|HOST_INTERNAL_HANDOFF_268a/i;
  const emptyComposer = (text) => text.split("\n").some((line) => /^[ \t]*(?:┃|❯|>)[ \t]*$/.test(line));
  const records = new Map();
  const requests = [];
  let revision = 0, commits = 0, summaries = 0, ordinary = 0;
  let phase = "seed", hold;
  let active;
  const sessionStore = {
    load(id) {
      const record = records.get(id);
      return record ? { bytes: record.bytes.slice(), revision: record.revision } : null;
    },
    commit(id, bytes, expectedRevision) {
      const current = records.get(id);
      if (current?.revision !== expectedRevision) {
        throw Object.assign(new Error("session revision conflict"), { code: "FX_SESSION_REVISION_CONFLICT" });
      }
      const next = String(++revision);
      records.set(id, { bytes: bytes.slice(), revision: next, updatedAtMs: Date.now() });
      commits++;
      return { revision: next };
    },
    list() { return [...records].map(([id, value]) => ({ id, updatedAtMs: value.updatedAtMs })); },
    remove(id) { records.delete(id); },
  };
  const fetch = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") {
      return Response.json({ data: [{ id: "fixture/test-model", type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
    }
    const body = JSON.parse(typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body));
    requests.push(body);
    // A compaction request writes the turns out without tools, or follows the
    // conversation with the notes request.
    const notesAfterConversation = JSON.stringify(body.messages?.at(-1) ?? "").includes("Write the compaction notes for the turns of the conversation above");
    if ((body.toolChoice?.type === "none" && body.tools?.length === 0) || notesAfterConversation) {
      summaries++;
      // Retained windows vary by model; summarize only markers actually supplied.
      const source = JSON.stringify(body);
      const markers = [head, tail].filter((marker) => source.includes(marker));
      handoff = `Rules:\n- R1 (M1): "${seedRule}"\n\nFacts:\n- F1 (M1): HOST_INTERNAL_HANDOFF_268a: preserve ${markers.join(" and ")}; follow the latest request.`;
      if (summaries === 1) {
        hold = heldSummary(init.signal);
        return hold.response;
      }
      return finalText(handoff);
    }
    ordinary++;
    return finalText(phase === "seed"
      ? seedReply(ordinary)
      : phase === "reopen" ? "HOST_REOPEN_OK_732a" : "HOST_FOLLOWUP_OK_781c");
  };
  async function waitFor(predicate, label, timeout = 10_000) {
    const deadline = performance.now() + timeout;
    while (true) {
      await new Promise((resolve) => active.terminal.write("", resolve));
      if (predicate()) return;
      assert(performance.now() < deadline, `${name}: timed out waiting for ${label}\n${grid(active.terminal).slice(-6000)}`);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  async function start(args = []) {
    const terminal = new Terminal({ cols: 90, rows: 32, allowProposedApi: true, scrollback: 4000 });
    const adapter = xtermAdapter(terminal);
    const state = { terminal, writes: 0, stderr: "", events: [], runtime: undefined };
    active = state;
    state.runtime = await createFxTerminal({
      backend: "wasm", wasm, args,
      terminal: {
        ...adapter,
        get cols() { return adapter.cols; },
        get rows() { return adapter.rows; },
        write(bytes) { state.writes++; adapter.write(bytes); },
      },
      env: {
        AI_GATEWAY_API_KEY: "synthetic-host-compaction-key", FX_MODEL: "fixture/test-model",
        FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1",
      },
      fetch, sessionStore,
      configStore: { get(id) { return id === "model" ? "fixture/test-model" : null; }, set() {} },
      stderr(bytes) { state.stderr += new TextDecoder().decode(bytes); },
      onEvent(event) { state.events.push(event); },
    });
    await waitFor(() => grid(terminal).includes(args.length ? "session resumed" : "Run /help for commands") && emptyComposer(grid(terminal)), "terminal startup");
    return state;
  }
  async function stop() {
    const state = active;
    state.runtime.write("/exit\r");
    const code = await Promise.race([
      state.runtime.exited,
      new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error("terminal exit timeout")), 5000); timer.unref(); }),
    ]);
    assert.equal(code, 0);
    assert.equal(state.stderr, "");
    assert.equal(state.events.filter((event) => event.type === "runtime.exit").length, 1);
    state.terminal.dispose();
    active = undefined;
  }
  async function ticking(label) {
    await waitFor(() => activity.test(grid(active.terminal)), `${label} activity`);
    const first = grid(active.terminal).match(activity)[0];
    const writes = active.writes;
    const markerStates = new Set();
    await waitFor(() => {
      const rows = grid(active.terminal).split("\n").filter((line) => activity.test(line));
      assert.equal(rows.length, 1, "exactly one live activity row");
      assert(!/[↑↓]|tokens|chunk|%/i.test(rows[0]), "compaction must not show a token suffix");
      markerStates.add(rows[0].includes("•"));
      return markerStates.size === 2 && !rows[0].includes(first) && active.writes >= writes + 2;
    }, `${label} marker blink and elapsed time`, 5000);
  }
  async function silentTranscript() {
    assert(!forbidden.test(grid(active.terminal)), "compaction output leaked into inline scrollback");
    active.runtime.write("\x0f");
    await waitFor(() => active.terminal.buffer.active.type === "alternate" && grid(active.terminal).includes("full detail"), "full transcript");
    assert(!forbidden.test(grid(active.terminal)), "compaction output leaked into Ctrl+O");
    active.runtime.write("\x0f");
    await waitFor(() => active.terminal.buffer.active.type === "normal" && emptyComposer(grid(active.terminal)), "inline restoration");
  }
  try {
    await start();
    for (let turn = 1; turn <= seedTurns; turn++) {
      active.runtime.write(`Seed ordinary historical turn ${turn}.${turn === 1 ? ` ${seedRule}` : ""}\r`);
      await waitFor(() => commits === turn && grid(active.terminal).includes(`HOST_SEED_DONE_${turn}`) && emptyComposer(grid(active.terminal)), `saved history turn ${turn}`, 20_000);
      assert.equal(ordinary, turn);
      assert.equal(summaries, 0, "seed history must stay below automatic compaction");
    }
    assert.equal(records.size, 1);
    const sessionId = [...records.keys()][0];
    await stop();
    phase = "attempt";
    await start(["--resume", sessionId]);
    // A known context window bounds the turns kept unchanged, so older turns compact.
    active.runtime.write("/model\r");
    await waitFor(() => grid(active.terminal).includes("128K context") && grid(active.terminal).includes("tab provider"), "model capabilities loaded");
    active.runtime.write("\x1b");
    await waitFor(() => !grid(active.terminal).includes("tab provider") && emptyComposer(grid(active.terminal)), "model catalog closed");
    const beforeCommits = commits;
    const beforeBytes = [...records.values()][0].bytes.slice();
    const cancelledPrompt = "Cancel this automatic summary before headers.";
    active.runtime.write(automatic ? `${cancelledPrompt}\r` : "/compact\r");
    await waitFor(() => summaries === 1 && hold, "summary held before headers");
    await ticking("held headers");
    assert.equal(commits, beforeCommits, "checkpoint before headers released");
    assert.deepEqual([...records.values()][0].bytes, beforeBytes);
    assert.equal(ordinary, seedTurns, "manual compaction created an ordinary prompt");
    assert(JSON.stringify(requests.at(-1)).includes(automatic ? "Seed ordinary historical turn 1." : head), `summary must receive real older history: ${JSON.stringify(requests.at(-1)).slice(-4000)}`);
    if (name !== "cancel-headers" && !automatic) {
      hold.releaseHeaders();
      await waitFor(() => hold.bodyRead, "summary body read reached");
      await ticking("held body");
      assert.equal(commits, beforeCommits, "checkpoint before summary body released");
    }
    if (name === "success") {
      await hold.releaseBody(handoff);
      await waitFor(() => commits > beforeCommits && !activity.test(grid(active.terminal)) && emptyComposer(grid(active.terminal)), "published summary and idle composer");
      assert.equal(ordinary, seedTurns, "manual completion created a synthetic prompt");
      assert.notDeepEqual(records.get(sessionId).bytes, beforeBytes, "success must publish a changed checkpoint");
    } else {
      active.runtime.write("\x03");
      await waitFor(() => hold.aborted, "Ctrl+C reaches summary AbortSignal");
      await waitFor(() => !activity.test(grid(active.terminal)) && grid(active.terminal).includes("Compaction cancelled.") && emptyComposer(grid(active.terminal)), "scoped cancellation feedback");
      if (automatic) {
        await waitFor(() => commits === beforeCommits + 1, "automatic interruption persisted");
        const saved = new TextDecoder().decode(records.get(sessionId).bytes);
        assert.equal(saved.match(/"cancellation_origin"\s*:\s*"compaction"/g)?.length, 1, "save one compaction-origin interruption");
        assert(saved.includes(cancelledPrompt), "save the interrupted prompt");
        assert(!saved.includes("HOST_INTERNAL_HANDOFF_268a"), "unacknowledged summary must not enter history");
        assert.equal(ordinary, seedTurns, "cancelled automatic turn must not request an ordinary reply");
      } else {
        assert.equal(commits, beforeCommits, "cancelled summary committed a checkpoint");
        assert.deepEqual(records.get(sessionId).bytes, beforeBytes, "cancelled summary changed saved history");
      }
      active.runtime.write("\x1b");
      await waitFor(() => !/compact/i.test(grid(active.terminal)), "feedback dismissal");
    }
    await silentTranscript();
    if (automatic) {
      await stop();
      phase = "reopen";
      await start(["--resume", sessionId]);
      active.runtime.write("\x0f");
      await waitFor(() => active.terminal.buffer.active.type === "alternate" && grid(active.terminal).includes("full detail"), "reopened full transcript");
      active.runtime.write("\x1b[F");
      await waitFor(() => grid(active.terminal).includes(cancelledPrompt), "replayed interrupted prompt");
      assert(!/cancelled|compaction|HOST_INTERNAL_HANDOFF_268a/i.test(grid(active.terminal)), "compaction cancellation must replay silently");
      active.runtime.write("\x0f");
      await waitFor(() => active.terminal.buffer.active.type === "normal" && emptyComposer(grid(active.terminal)), "reopened inline restoration");
      await stop();
      assert.equal(summaries, 1);
      assert.equal(ordinary, seedTurns);
      console.log(`term compaction ${name} passed`);
      return;
    }
    phase = "followup";
    active.runtime.write("Follow the latest request.\r");
    await waitFor(() => grid(active.terminal).includes("HOST_FOLLOWUP_OK_781c") && emptyComposer(grid(active.terminal)), "followup");
    assert.equal(ordinary, seedTurns + 1);
    assert.equal(summaries, 1, "followup must not trigger automatic compaction");
    const followup = JSON.stringify(requests.at(-1));
    assert(followup.includes(head) && followup.includes(tail), JSON.stringify(requests.map((request) => ({
      summary: request.toolChoice?.type === "none" && request.tools?.length === 0,
      head: JSON.stringify(request).includes(head), tail: JSON.stringify(request).includes(tail),
      handoff: JSON.stringify(request).includes("HOST_INTERNAL_HANDOFF_268a"),
    }))));
    assert.equal(followup.includes("HOST_INTERNAL_HANDOFF_268a"), name === "success");
    await silentTranscript();
    await stop();
    phase = "reopen";
    await start(["--resume", sessionId]);
    assert.equal(records.size, 1, "reopen must use the same saved history");
    active.runtime.write("Continue after reopening.\r");
    await waitFor(() => grid(active.terminal).includes("HOST_REOPEN_OK_732a") && emptyComposer(grid(active.terminal)), "reopened prompt");
    assert.equal(ordinary, seedTurns + 2);
    assert.equal(summaries, 1, "reopen must not trigger automatic compaction");
    const reopened = JSON.stringify(requests.at(-1));
    assert(reopened.includes(head) && reopened.includes(tail));
    assert.equal(reopened.includes("HOST_INTERNAL_HANDOFF_268a"), name === "success");
    await silentTranscript();
    await stop();
    console.log(`term compaction ${name} passed`);
  } finally {
    if (active) {
      active.runtime?.abort();
      active.terminal.dispose();
    }
  }
}
