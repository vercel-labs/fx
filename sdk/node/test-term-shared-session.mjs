#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

const terminal = new Terminal({ cols: 100, rows: 34, allowProposedApi: true, scrollback: 2000 });
const config = new Map([["model", "test/shared-model"], ["mode", "ask"]]);
const requests = [];
const encoder = new TextEncoder();
let releaseTerminalTurn;
const terminalTurnReleased = new Promise((resolve) => { releaseTerminalTurn = resolve; });

const fetch = async (_url, init = {}) => {
  const body = JSON.parse(new TextDecoder().decode(init.body));
  requests.push(body);
  const responseNumber = requests.length;
  return new Response(new ReadableStream({
    async start(controller) {
      if (responseNumber === 1) {
        controller.enqueue(encoder.encode('data: {"type":"text-delta","delta":"terminal answer"}\n'));
        await terminalTurnReleased;
      } else if (responseNumber === 3) {
        controller.enqueue(encoder.encode('data: {"type":"text-delta","delta":"cancellable answer"}\n'));
        await new Promise((resolve) => init.signal.addEventListener("abort", resolve, { once: true }));
        controller.error(new DOMException("cancelled by attached session", "AbortError"));
        return;
      } else {
        controller.enqueue(encoder.encode('data: {"type":"text-delta","delta":"api answer"}\n'));
      }
      controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n'));
      controller.enqueue(encoder.encode("data: [DONE]\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

let stderr = "";
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: { AI_GATEWAY_API_KEY: "shared-session-key" },
  fetch,
  configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
  stderr(chunk) { stderr += new TextDecoder().decode(chunk); },
});

const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
};
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${stderr}\n${grid()}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function withTimeout(promise, label, timeoutMs = 5000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timeout`)), timeoutMs); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

await withTimeout(Promise.all([runtime.interactive, runtime.session.ready]), "shared session startup");
await waitFor(() => grid().includes("𝒇x"), "startup");
const initialSessionId = runtime.session.id;
if (!initialSessionId) throw new Error("attached API did not expose the live terminal session id");
if (runtime.session.model !== "test/shared-model" || runtime.session.permissionMode !== "ask") {
  throw new Error(`attached state did not match terminal config: ${JSON.stringify(runtime.session.state)}`);
}
runtime.write("/permissions auto\r");
await waitFor(() => runtime.session.permissionMode === "auto", "terminal permission mode in attached state");

const sessionEvents = [];
const unsubscribe = runtime.session.onEvent((event) => sessionEvents.push(event));
runtime.write("terminal question\r");
await waitFor(() => requests.length === 1, "active terminal turn");

const apiTurn = runtime.session.prompt("api question");
const updatesPromise = (async () => {
  const updates = [];
  for await (const update of apiTurn) updates.push(update);
  return updates;
})();
await new Promise((resolve) => setTimeout(resolve, 20));
if (requests.length !== 1) throw new Error("attached prompt bypassed the active terminal turn instead of entering the FIFO");

releaseTerminalTurn();
const stopReason = await withTimeout(apiTurn.stopReason, "attached turn", 8000);
const updates = await updatesPromise;
await waitFor(() => grid().includes("terminal answer") && grid().includes("api answer"), "both shared answers in terminal");

if (stopReason !== "completed") throw new Error(`unexpected attached turn outcome: ${stopReason}`);
if (requests.length !== 2) throw new Error(`expected two shared gateway turns, got ${requests.length}`);
const secondBody = JSON.stringify(requests[1]);
for (const expected of ["terminal question", "terminal answer", "api question"]) {
  if (!secondBody.includes(expected)) throw new Error(`attached turn omitted shared history ${expected}: states=${JSON.stringify(sessionEvents.filter((event) => event.type === "session.state"))} body=${secondBody}`);
}
if (!updates.some((update) => update.sessionUpdate === "user_message" && update.source === "structured" && update.content.text === "api question")) {
  throw new Error(`attached turn omitted its structured user update: ${JSON.stringify(updates)}`);
}
if (!updates.some((update) => update.sessionUpdate === "agent_message_chunk" && update.content.text.includes("api answer"))) {
  throw new Error(`attached turn omitted the semantic agent stream: ${JSON.stringify(updates)}`);
}
if (!updates.some((update) => update.sessionUpdate === "turn_finished" && update.outcome === "completed")) {
  throw new Error(`attached turn omitted its terminal event: ${JSON.stringify(updates)}`);
}
if (!sessionEvents.some((event) => event.type === "session.update" && event.update?.source === "terminal")) {
  throw new Error("attached event stream did not observe the terminal-owned turn");
}
const terminalTurnId = sessionEvents.find((event) => event.type === "session.update" && event.update?.source === "terminal")?.turnId;
if (terminalTurnId === apiTurn.id) throw new Error("terminal and attached prompts reused the same turn identity");
if (runtime.session.id !== initialSessionId) throw new Error("terminal and attached API diverged to different sessions");

const cancellableTurn = runtime.session.prompt("cancel this turn");
const cancellableUpdatesPromise = (async () => {
  const turnUpdates = [];
  for await (const update of cancellableTurn) turnUpdates.push(update);
  return turnUpdates;
})();
await waitFor(() => requests.length === 3 && cancellableTurn.started, "active cancellable API turn");
const cancellation = await withTimeout(cancellableTurn.cancel(), "attached cancellation");
if (!cancellation.cancelled) throw new Error(`attached cancellation was not admitted: ${JSON.stringify(cancellation)}`);
const cancelledOutcome = await withTimeout(cancellableTurn.stopReason, "cancelled turn");
const cancellableUpdates = await cancellableUpdatesPromise;
if (cancelledOutcome !== "interrupted" || !cancellableUpdates.some((update) => update.sessionUpdate === "turn_finished" && update.outcome === "interrupted")) {
  throw new Error(`attached cancellation did not preserve its turn boundary: outcome=${cancelledOutcome} updates=${JSON.stringify(cancellableUpdates)}`);
}

unsubscribe();
runtime.write("/exit\r");
const code = await withTimeout(runtime.exited, "terminal exit");
if (code !== 0) throw new Error(`fx-term exited with ${code}`);
if (stderr.trim()) throw new Error(`shared terminal session wrote unexpected stderr: ${stderr}`);
console.log("shared terminal session passed: terminal and structured prompts used one FIFO, history, and event stream");
