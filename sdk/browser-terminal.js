// The fx terminal for `libfx/browser`, with its packaged fx-term.wasm.
import { createFxTerminal as createWasmTerminal } from "./wasm-terminal.js";

export function createFxTerminal(options = {}) {
  // A literal URL, which bundlers rewrite to the fx-term.wasm they emit.
  return createWasmTerminal({ ...options, wasm: options.wasm ?? new URL("./fx-term.wasm", import.meta.url).href });
}
