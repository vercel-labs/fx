// The WebAssembly backend in Node. node.js imports this module only when the
// native addon is unavailable and the runtime supports JSPI, so a process
// that runs natively never loads the WebAssembly host.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bundledAssetUrl } from "./bundled-asset.js";
import { createFxEngine as createEngine } from "./engine.js";
import { loadModule, withModuleFailure } from "./wasm-module.js";
import { wasmRuntimeFactory } from "./wasm-runtime.js";

const wasmFilePromises = new Map();

// Each URL is a literal, so a bundler copies the module it names.
function packagedWasm(surface) {
  return surface === "agent" ? new URL("./fx-core.wasm", import.meta.url) : new URL("./fx-term.wasm", import.meta.url);
}

// Reads a file URL or path once per absolute path; any other input passes
// through. readFile takes the input itself, which fs resolves as
// path.resolve() would: Turbopack traces this whole package for a read of a
// path computed from an unknown value.
function wasmInput(input) {
  if (input instanceof URL && input.protocol === "") input = bundledAssetUrl(input);
  const path = wasmFilePath(input);
  if (path === null) {
    if (input instanceof URL) return input.href;
    return input;
  }
  const cached = wasmFilePromises.get(path);
  if (cached) return cached;
  const pendingRead = readFile(input);
  let pending;
  pending = withModuleFailure(pendingRead, () => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  wasmFilePromises.set(path, pending);
  pendingRead.catch(() => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  return pending;
}

// The absolute path a file input names, or null for anything else.
function wasmFilePath(input) {
  if (input instanceof URL) return input.protocol === "file:" ? fileURLToPath(input) : null;
  if (typeof input === "string" && !URL.canParse(input)) return resolve(input);
  return null;
}

// Compiles the module for `surface` without starting it.
export async function probeWasm(surface, wasm) {
  await loadModule(await wasmInput(wasm ?? packagedWasm(surface)));
}

export async function createWasmEngine(options) {
  return createEngine({ ...options, wasm: await wasmInput(options.wasm ?? packagedWasm("agent")) }, wasmRuntimeFactory());
}

export async function createWasmTerminal(options) {
  const { createFxTerminal } = await import("./wasm-terminal.js");
  return createFxTerminal({ ...options, wasm: await wasmInput(options.wasm ?? packagedWasm("terminal")) });
}
