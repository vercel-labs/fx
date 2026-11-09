// The agent and engine for `libfx/browser`, with their packaged fx-core.wasm.
import { createDurableAgentFactory, memory } from "./durable.js";
import { createFxEngine as createEngine } from "./engine.js";
import { fxHarness } from "./fx-harness.js";
import { wasmRuntimeFactory } from "./wasm-runtime.js";

export const libfxApiVersion = 3;

/** One fx session on WebAssembly, with no durability of its own. */
export function createFxEngine(options = {}) {
  // A literal URL, which bundlers rewrite to the fx-core.wasm they emit.
  return createEngine({ ...options, wasm: options.wasm ?? new URL("./fx-core.wasm", import.meta.url).href }, wasmRuntimeFactory());
}

/** An agent whose sessions live in this page unless `durability` says otherwise. */
export const createFxAgent = /* @__PURE__ */ createDurableAgentFactory({
  name: "createFxAgent",
  label: "fx agent",
  defaultDurability: async () => memory(),
  harness: /* @__PURE__ */ fxHarness({ createEngine: createFxEngine }),
});
