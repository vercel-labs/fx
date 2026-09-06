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
const config = new Map([["model", "test/feature-model"], ["mode", "ask"]]);
const requests = [];
const catalog = {
  object: "list",
  data: [
    { id: "test/feature-model", type: "language", released: 2, tags: ["tool-use", "reasoning"], context_window: 128000, max_tokens: 8192 },
    { id: "test/other-model", type: "language", released: 1, tags: ["tool-use"], context_window: 64000, max_tokens: 4096 },
  ],
};
const encoder = new TextEncoder();
let turn = 0;
const fetch = async (url, init = {}) => {
  if ((init.method || "GET") === "GET") {
    return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
  }
  const body = JSON.parse(new TextDecoder().decode(init.body));
  requests.push(body);
  turn += 1;
  const response = turn === 1 ? "first answer" : "second answer";
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: {"type":"text-delta","delta":"${response}"}\n\n`));
      controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};
const stderrDecoder = new TextDecoder();
let stderrText = "";
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: {
    AI_GATEWAY_API_KEY: "feature-key",
    FX_TRACE_STDERR: "1",
    FX_TRACE_SCOPES: "full_transcript,full_transcript_cache,frame_schedule",
  },
  fetch,
  configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
  stderr(chunk) { stderrText += stderrDecoder.decode(chunk, { stream: true }); },
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  return lines.join("\n");
};
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) {
      const trace = stderrText.split("\n").slice(-50).join("\n");
      throw new Error(`timed out waiting for ${label}:\n${trace}\n${grid()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function command(text, expected) {
  runtime.write(`${text}\r`);
  await waitFor(() => grid().includes(expected), expected);
}

await waitFor(() => grid().includes("𝒇x"), "startup");
await command("first question", "first answer");
await command("second question", "second answer");
if (requests.length !== 2) throw new Error(`expected two gateway turns, got ${requests.length}`);
const secondBody = JSON.stringify(requests[1]);
for (const expected of ["first question", "first answer", "second question"]) {
  if (!secondBody.includes(expected)) throw new Error(`second turn omitted ${expected}: ${secondBody}`);
}

runtime.write("\x0f");
await waitFor(() => terminal.buffer.active.type === "alternate", "full transcript alternate screen");
runtime.write("\x1b[C");
await waitFor(() => grid().includes("Full detail"), "full transcript detail");
runtime.write("\x0f");
await waitFor(() => terminal.buffer.active.type === "normal", "full transcript close");

await command("/login", "Vercel sign-in failed. The current credential is unchanged.");
await command("/resume", "Session resume is owned by the embedding SDK");
await command("/mcp list", "No MCP servers configured");
await command("/skills list", "Skills are unavailable in this host");

runtime.write("/model\r");
await waitFor(() => grid().includes("feature-model") && grid().includes("other-model"), "model catalog menu");
runtime.write("\x1b");
await waitFor(() => !grid().includes("Tab Provider"), "model catalog close");

runtime.write("/exit\r");
const code = await Promise.race([runtime.exited, new Promise((_, reject) => setTimeout(() => reject(new Error("exit timeout")), 5000))]);
if (code !== 0) throw new Error(`fx-term exited with ${code}`);
console.log("headless features passed: history, transcript, catalog, and host degradation");
