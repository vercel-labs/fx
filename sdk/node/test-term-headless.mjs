#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run through: npm run test:term");
  process.exit(2);
}

const terminal = new Terminal({ cols: 96, rows: 30, allowProposedApi: true });
const config = new Map([
  ["model", "sdk/headless-model"],
  ["mode", "plan"],
]);
const events = [];
const encoded = new TextEncoder();
let requestedModel;
let firstChunkAt;
const startedAt = performance.now();
const mockFetch = async (_url, init) => {
  requestedModel = new Headers(init.headers).get("ai-language-model-id");
  return new Response(new ReadableStream({
    async start(controller) {
      firstChunkAt = performance.now();
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"streamed"}\n\n'));
      await new Promise((resolve) => setTimeout(resolve, 20));
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":" response"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  configStore: {
    get(id) { return config.get(id) ?? null; },
    set(id, value) { config.set(id, value); },
  },
  env: { AI_GATEWAY_API_KEY: "term-headless-key" },
  fetch: mockFetch,
  onEvent(event) { events.push(event); },
});
const flushTerminal = () => new Promise((resolve) => terminal.write("", resolve));
const readGrid = () => {
  const lines = [];
  const buffer = terminal.buffer.active;
  for (let row = 0; row < buffer.length; row++) lines.push(buffer.getLine(row)?.translateToString(true) ?? "");
  return lines.join("\n");
};
const startupDeadline = performance.now() + 5000;
while (!readGrid().includes("𝒇x")) {
  await flushTerminal();
  if (performance.now() >= startupDeadline) throw new Error(`timed out waiting for fx-term startup:\n${readGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
// fx reads the size on every pass of its loop; an idle terminal reports
// only the one size it has, not a diagnostic a frame.
await new Promise((resolve) => setTimeout(resolve, 500));
const idleSizeEvents = events.filter((event) => event.type === "terminal.size");
if (idleSizeEvents.length !== 1) {
  throw new Error(`an idle terminal reported its size ${idleSizeEvents.length} times in 500ms; expected once`);
}
runtime.write("/model sdk/accepted-model\r");
const modelDeadline = performance.now() + 5000;
while (!(events.some((event) => event.type === "config.changed" && event.configId === "model") &&
  config.get("model") === "sdk/accepted-model")) {
  if (performance.now() >= modelDeadline) throw new Error(`timed out waiting for model change:\n${readGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
runtime.write("/permissions auto\r");
const modeDeadline = performance.now() + 5000;
while (!(events.some((event) => event.type === "config.changed" && event.configId === "mode") &&
  config.get("mode") === "auto")) {
  if (performance.now() >= modeDeadline) throw new Error(`timed out waiting for mode change:\n${readGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
runtime.write("finished\r");
const streamDeadline = performance.now() + 5000;
while (!readGrid().includes("streamed response")) {
  await flushTerminal();
  if (performance.now() >= streamDeadline) throw new Error(`timed out waiting for rendered fx-term stream; requestedModel=${requestedModel}; events=${JSON.stringify(events)}:\n${readGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await flushTerminal();
const grid = readGrid();
// The configStore saved the model and the mode: fx says nothing about a
// user settings file this host doesn't have.
const notSaved = grid.split("\n").filter((line) => /not saved/.test(line));
if (notSaved.length) throw new Error(`terminal said accepted settings were not saved:\n${notSaved.join("\n")}`);
const savedModeBeforeReset = config.get("mode");
runtime.write("/permissions reset\r");
const resetDeadline = performance.now() + 5000;
while (config.get("mode") !== "ask") {
  if (performance.now() >= resetDeadline) throw new Error(`/permissions reset did not save mode ask to configStore (mode=${config.get("mode")}):\n${readGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
runtime.write("/exit\r");

const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for fx-term exit")), 5000)),
]);

if (exitCode !== 0) throw new Error(`fx-term exited with code ${exitCode}`);
if (!grid.includes("𝒇x")) throw new Error(`shared fx welcome frame was not visible in xterm grid:\n${grid}`);
if (!grid.includes("Run /help for commands")) throw new Error(`shared fx welcome guidance was not visible in xterm grid:\n${grid}`);
if (terminal.buffer.active.baseY !== 0 || terminal.buffer.active.viewportY !== 0) {
  throw new Error(`fresh xterm startup created blank scrollback: baseY=${terminal.buffer.active.baseY}, viewportY=${terminal.buffer.active.viewportY}`);
}
if (!events.some((event) => event.type === "terminal.size" && event.cols === 96 && event.rows === 30)) throw new Error("terminal.size event did not report headless xterm geometry");
if (config.get("model") !== "sdk/accepted-model") throw new Error("accepted terminal model was not persisted through configStore");
if (!events.some((event) => event.type === "config.changed" && event.configId === "model" && event.value === "sdk/accepted-model" && event.source === "terminal")) throw new Error("terminal model command did not emit config.changed");
if (savedModeBeforeReset !== "auto") throw new Error("accepted terminal mode was not persisted through configStore");
if (!events.some((event) => event.type === "config.changed" && event.configId === "mode" && event.value === "auto" && event.source === "terminal")) throw new Error("terminal mode command did not emit config.changed");
if (!grid.includes("streamed response")) throw new Error(`terminal prompt did not render streamed gateway text:\n${grid}`);
if (requestedModel !== "sdk/accepted-model") throw new Error(`terminal prompt used unexpected accepted model: ${requestedModel}`);
if (!(firstChunkAt >= startedAt)) throw new Error("terminal fetch did not produce a first stream chunk");
// The DiagnosticEvent table's transport events, for the terminal's model
// request: a start and its response, paired by attempt, with no query.
const starts = events.filter((event) => event.type === "transport.start" && event.method === "POST");
const responses = events.filter((event) => event.type === "transport.response");
if (!starts.length) throw new Error(`no transport.start for the model request: ${JSON.stringify(events.map((event) => event.type))}`);
for (const start of starts) {
  const response = responses.find((event) => event.attempt === start.attempt);
  if (!response || response.status !== 200 || !(response.elapsedMs >= 0)) {
    throw new Error(`request ${start.attempt} has no transport.response with status 200: ${JSON.stringify(responses)}`);
  }
  if (!start.endpoint.startsWith("https://") || start.endpoint.includes("?")) {
    throw new Error(`transport.start endpoint should be an origin and path: ${start.endpoint}`);
  }
}

console.log("headless xterm smoke passed: shared fx frame used the 96x30 host cell grid");
