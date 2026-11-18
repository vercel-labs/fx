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
const encoder = new TextEncoder();
const markdown = [
  "| name | light | status |",
  "| --- | --- | --- |",
  "| basil | sun | ready to harvest |",
  "| mint | shade | needs water |",
].join("\n") + "\n";

const fetch = async () => new Response(new ReadableStream({
  start(controller) {
    for (let offset = 0; offset < markdown.length; offset += 4) {
      const delta = markdown.slice(offset, offset + 4);
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", delta })}\n\n`));
    }
    controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
    controller.enqueue(encoder.encode("data: [DONE]\n\n"));
    controller.close();
  },
}), { status: 200, headers: { "content-type": "text/event-stream" } });

const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: { AI_GATEWAY_API_KEY: "table-stream-key" },
  fetch,
  configStore: { get(id) { return id === "model" ? "test/table-model" : null; }, set() {} },
});

const flush = () => new Promise((resolveFlush) => terminal.write("", resolveFlush));
const grid = () => {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
};
const deadline = performance.now() + 5000;
while (!grid().includes("run /help for commands")) {
  await flush();
  if (performance.now() >= deadline) throw new Error(`timed out waiting for startup:\n${grid()}`);
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
}

runtime.write("Show data/plants.csv as a markdown table\r");
const tableDeadline = performance.now() + 5000;
while (!grid().includes("needs water")) {
  await flush();
  if (performance.now() >= tableDeadline) throw new Error(`timed out waiting for table:\n${grid()}`);
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
}
await flush();

const rendered = grid();
const lines = rendered.split("\n");
if (!rendered.includes("┌")) throw new Error(`streamed markdown did not render a boxed table:\n${rendered}`);
if (!lines.some((line) => line.includes("│ name"))) throw new Error(`boxed table omitted the name header:\n${rendered}`);
if (rendered.includes("|--")) throw new Error(`streamed markdown leaked a table delimiter fragment:\n${rendered}`);
if (lines.some((line) => /^─{90,}$/.test(line.trim()))) {
  throw new Error(`streamed table emitted a terminal-width thematic rule:\n${rendered}`);
}

runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("exit timeout")), 5000)),
]);
if (exitCode !== 0) throw new Error(`fx-term exited with ${exitCode}`);

console.log("headless table stream passed: four-character deltas rendered one boxed table");
