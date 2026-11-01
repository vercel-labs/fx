// `libfx` in browsers, and `libfx/browser`. Importing it does no work: each
// factory names its WebAssembly module only when called, so a server can render
// a client component that imports it.
//
// This module only re-exports, and each .wasm is named in the module of the
// factory that loads it. A bundler that skips unused re-exports, such as
// Rolldown with lazy barrel optimization, then emits only the .wasm an app uses.
export { createFxAgent, createFxEngine, libfxApiVersion } from "./browser-agent.js";
export { createFxTerminal } from "./browser-terminal.js";
export { memory } from "./durable.js";
export { createMemoryPersistence, FxFencedError, FxJournalVersionError, fxSdkApiVersion, listModels, supportsJspi } from "./engine.js";
export { encodeXtermKeyEvent, xtermAdapter } from "./xterm.js";
