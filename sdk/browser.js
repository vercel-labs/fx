import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  createMemoryJournal,
  FxConfigMismatchError,
  FxFencedError,
  FxJournalVersionError,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  worldHandler,
  xtermAdapter,
} from "./fx-sdk.js";

export { createMemoryJournal, encodeXtermKeyEvent, FxConfigMismatchError, FxFencedError, FxJournalVersionError, fxSdkApiVersion, listModels, supportsJspi, worldHandler, xtermAdapter };
export const libfxApiVersion = 2;

const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url).href;

export function createFxAgent(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

export function createFxTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
