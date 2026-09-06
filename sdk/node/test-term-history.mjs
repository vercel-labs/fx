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
const wasm = await readFile(wasmPath);
const histories = new Map();
const promptHistoryStore = {
  load(workspaceRoot, limit) { return (histories.get(workspaceRoot) || []).slice(-limit); },
  append(workspaceRoot, value) {
    const values = histories.get(workspaceRoot) || [];
    if (values.at(-1) === value) return "duplicate";
    values.push(value);
    histories.set(workspaceRoot, values);
  },
  clear(workspaceRoot) { histories.delete(workspaceRoot); },
};
const encoded = new TextEncoder();
const fetch = async () => new Response(new ReadableStream({
  start(controller) {
    controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
    controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop"}}\n\n'));
    controller.enqueue(encoded.encode("data: [DONE]\n\n"));
    controller.close();
  },
}), { status: 200, headers: { "content-type": "text/event-stream" } });

function grid(terminal) {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}
async function waitFor(terminal, predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await new Promise((resolve) => terminal.write("", resolve));
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${grid(terminal)}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function waitForExit(runtime, label) {
  return Promise.race([
    runtime.exited,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${label} exit`)), 5000)),
  ]);
}
async function start() {
  const terminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
  const events = [];
  const runtime = await createFxTerminal({
  backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: { AI_GATEWAY_API_KEY: "term-history-key" },
    fetch,
    promptHistoryStore,
    onEvent(event) { events.push(event); },
  });
  await waitFor(terminal, () => grid(terminal).includes("Run /help for commands"), "startup");
  return { terminal, runtime, events };
}

const first = await start();
first.runtime.write("remember this prompt\r");
await waitFor(first.terminal, () => first.events.some((event) => event.type === "history.append"), "history append");
first.runtime.write("/exit\r");
if (await waitForExit(first.runtime, "first terminal") !== 0) throw new Error("first terminal did not exit cleanly");

const second = await start();
await waitFor(
  second.terminal,
  () => second.events.some((event) => event.type === "history.restore" || event.type === "history.restore_error"),
  "host history restore",
);
const restoreError = second.events.find((event) => event.type === "history.restore_error");
if (restoreError) throw restoreError.error;
if (!second.events.some((event) => event.type === "history.restore" && event.count === 2)) {
  throw new Error("second terminal did not restore the host prompt and slash command history entries");
}
second.runtime.write("\x1b[A");
await waitFor(second.terminal, () => grid(second.terminal).includes("/exit"), "restored Up-arrow slash command");
second.runtime.write("\x10");
await waitFor(second.terminal, () => grid(second.terminal).includes("remember this prompt"), "restored Ctrl-P prompt");
if (grid(second.terminal).includes("durable prompt history unavailable")) {
  throw new Error("terminal reported unavailable history despite a host provider");
}
second.runtime.write("\x15/exit\r");
if (await waitForExit(second.runtime, "second terminal") !== 0) throw new Error("second terminal did not exit cleanly");
console.log("headless history passed: host prompt and slash command history survived terminal recreation");
