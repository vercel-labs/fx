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

function terminalGrid(terminal) {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}

async function verifyStartup(label, configStore, expectedEvent, trigger, expectedDiagnostic) {
  const terminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true });
  const events = [];
  const stderrDecoder = new TextDecoder();
  let stderrText = "";
  let exited;
  const runtime = await createFxTerminal({
  backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: {
      AI_GATEWAY_API_KEY: "config-restore-test-key",
      FX_TRACE_STDERR: "1",
      FX_TRACE_SCOPES: "host_config",
    },
    configStore,
    stderr(chunk) { stderrText += stderrDecoder.decode(chunk, { stream: true }); },
    fetch: async () => new Response('{"object":"list","data":[]}', {
      status: 200,
      headers: { "content-type": "application/json" },
    }),
    onEvent(event) { events.push(event); },
  });
  runtime.exited.then((code) => { exited = code; });

  const flush = () => new Promise((resolveFlush) => terminal.write("", resolveFlush));
  const deadline = performance.now() + 5000;
  while (!terminalGrid(terminal).includes("run /help for commands")) {
    await flush();
    if (exited !== undefined) throw new Error(`${label} exited during startup with code ${exited}`);
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label} startup:\n${terminalGrid(terminal)}`);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
  }

  trigger?.(runtime);
  const eventDeadline = performance.now() + 5000;
  while (!events.some(expectedEvent) || (expectedDiagnostic && !stderrText.includes(expectedDiagnostic))) {
    await flush();
    if (exited !== undefined) throw new Error(`${label} exited before reporting the rejected host config value with code ${exited}`);
    if (performance.now() >= eventDeadline) throw new Error(`${label} did not report the rejected host config value`);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
  }
  runtime.write("/exit\r");
  const exitCode = await runtime.exited;
  if (exitCode !== 0) throw new Error(`${label} exited with code ${exitCode}`);
}

await verifyStartup(
  "throwing config store",
  { get() { throw new Error("storage unavailable"); } },
  (event) => event.type === "config.restore_error" && event.configId === "model",
);

await verifyStartup(
  "invalid stored model",
  { get(id) { return id === "model" ? "bad\nmodel" : null; } },
  (event) => event.type === "config.restore" && event.configId === "model",
  undefined,
  "restore_ignored id=model reason=invalid_value",
);

await verifyStartup(
  "throwing config store set",
  {
    get() { return null; },
    set() { throw new Error("quota exceeded"); },
  },
  (event) => event.type === "config.persist_error" && event.configId === "model",
  (runtime) => runtime.write("/model sdk/rejected-model\r"),
  "persist_ignored id=model reason=host_failure",
);

console.log("headless config restore passed: host read, validation, and write failures did not abort the runtime");
