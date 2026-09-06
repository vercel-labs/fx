import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";

export { encodeXtermKeyEvent, fxSdkApiVersion, listModels, supportsJspi, xtermAdapter };
export const libfxApiVersion = 2;

const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url).href;

export function createFxAgent(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

export function createFxTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
