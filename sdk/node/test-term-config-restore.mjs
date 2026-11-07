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
  while (!terminalGrid(terminal).includes("Run /help for commands")) {
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

// The config store owns preferences on fx-term.wasm, which has no settings
// file, so a preference change must not report a failed settings save. With
// HOME in the host env the old write failed with FileNotFound instead of
// HomeNotSet, and a store whose set() throws still reports only its own event.
const settingsFailures = ["not saved to global settings", "global settings persistence uncertain"];

function viewport(terminal) {
  const lines = [];
  const top = terminal.buffer.active.viewportY;
  for (let row = top; row < top + terminal.rows; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}

function count(text, needle) {
  return text.split(needle).length - 1;
}

async function verifyHostOwnedPreferences(label, env, throwOnSet = false) {
  const terminal = new Terminal({ cols: 160, rows: 40, allowProposedApi: true, scrollback: 2000 });
  const saved = [];
  const events = [];
  let fetches = 0;
  let exited;
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: { AI_GATEWAY_API_KEY: "host-owned-test-key", FX_SOUND: "0", ...env },
    configStore: {
      get() { return null; },
      set(id, value) {
        if (throwOnSet) throw new Error("quota exceeded");
        saved.push([id, value]);
      },
    },
    fetch: async () => {
      fetches += 1;
      return new Response('{"object":"list","data":[]}', {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
    onEvent(event) { events.push(event); },
  });
  runtime.exited.then((code) => { exited = code; });

  const flush = () => new Promise((resolveFlush) => terminal.write("", resolveFlush));
  const failure = () => settingsFailures.find((text) => terminalGrid(terminal).includes(text));
  async function waitFor(predicate, what) {
    const deadline = performance.now() + 5000;
    while (!predicate()) {
      await flush();
      if (exited !== undefined) throw new Error(`${label} exited with code ${exited} waiting for ${what}`);
      if (failure()) throw new Error(`${label} reported a settings save failure for ${what}:\n${terminalGrid(terminal)}`);
      if (performance.now() >= deadline) throw new Error(`${label} timed out waiting for ${what}:\n${terminalGrid(terminal)}`);
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
    }
  }
  const stored = (id, value) => throwOnSet
    ? events.some((event) => event.type === "config.persist_error" && event.configId === id)
    : saved.some(([key, item]) => key === id && item === value);

  await waitFor(() => terminalGrid(terminal).includes("Run /help for commands"), "startup");

  runtime.write("/model sdk/host-owned-model\r");
  await waitFor(() => stored("model", "sdk/host-owned-model") &&
    terminalGrid(terminal).includes("Switched to sdk/host-owned-model"), "/model");
  // Choosing the active model again changes nothing to save.
  runtime.write("/model sdk/host-owned-model\r");
  await waitFor(() => count(terminalGrid(terminal), "Switched to sdk/host-owned-model") === 2, "the same /model again");

  runtime.write("/permissions ask\r");
  await waitFor(() => stored("mode", "ask") && count(terminalGrid(terminal), "mode set to ask") === 1, "/permissions ask");

  // The first switch shows the full-access warning, and fx records that the
  // user saw it. The second switch must not warn again in this process.
  runtime.write("/permissions full-access\r");
  await waitFor(() => stored("mode", "full-access") && viewport(terminal).includes("Full access enabled"), "the full-access warning");
  runtime.write("/permissions ask\r");
  await waitFor(() => count(terminalGrid(terminal), "mode set to ask") === 2 && !viewport(terminal).includes("Full access enabled"), "/permissions ask again");
  runtime.write("/permissions full-access\r");
  await waitFor(() => count(terminalGrid(terminal), "mode set to full access") === 2, "/permissions full-access again");
  const footer = () => viewport(terminal).split("\n").filter((line) => line.trim()).slice(-2).join("\n");
  await waitFor(() => /full access ·/.test(footer()), "the full-access footer");
  if (viewport(terminal).includes("Full access enabled")) {
    throw new Error(`${label} warned about full access again after the user saw the warning:\n${viewport(terminal)}`);
  }

  runtime.write("/settings startup-scrollback off\r");
  await waitFor(() => terminalGrid(terminal).includes("startup_scrollback: off"), "/settings startup-scrollback off");

  if (fetches === 0) throw new Error(`${label} never reached the mock fetch`);
  runtime.write("/exit\r");
  const exitCode = await runtime.exited;
  if (exitCode !== 0) throw new Error(`${label} exited with code ${exitCode}`);
  const leftover = failure();
  if (leftover) throw new Error(`${label} reported "${leftover}":\n${terminalGrid(terminal)}`);
}

await verifyHostOwnedPreferences("host-owned preferences without HOME", {});
await verifyHostOwnedPreferences("host-owned preferences with HOME", { HOME: "/Users/example" });
await verifyHostOwnedPreferences("host-owned preferences with a throwing store", {}, true);

console.log("headless config restore passed: host read, validation, and write failures did not abort the runtime, and host-owned preferences reported no settings save failure");
