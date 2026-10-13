// `libfx/wasm` (fx-sdk.js): the WebAssembly SDK with no packaged asset paths,
// so every factory takes its `wasm` explicitly.
import type { FxEngine, FxEngineOptions, FxTerminal, FxTerminalOptions, FxWasmSource } from "./libfx.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  FxFencedError,
  FxJournalVersionError,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./libfx.cjs";

export type {
  FxApiKeyCredentials,
  FxBytes,
  FxCheckpointMeta,
  FxCodexProvider,
  FxCustomProvider,
  FxCustomProviderDefinition,
  FxCustomProviderModel,
  FxEffort,
  FxEngine,
  FxEngineEvent,
  FxEngineOptions,
  FxEnginePromptOptions,
  FxEngineStorage,
  FxEngineTurn,
  FxEngineTurnResult,
  FxErrorSummary,
  FxFetch,
  FxFollowUp,
  FxGatewayProvider,
  FxGrokProvider,
  FxHostTool,
  FxImageBlock,
  FxJsonSchema,
  FxKeyedTool,
  FxKeyEventLike,
  FxListModelsOptions,
  FxModelCatalogEntry,
  FxModelChoice,
  FxModelOptions,
  FxOnAmbiguous,
  FxPromptBlock,
  FxPromptInput,
  FxProviderCredentials,
  FxProviderTool,
  FxResizedImage,
  FxResourceBlock,
  FxResumeOptions,
  FxSharedOptions,
  FxSteer,
  FxSteeringInput,
  FxStopReason,
  FxTerminal,
  FxTerminalAdapter,
  FxTerminalEvent,
  FxTerminalOptions,
  FxTextBlock,
  FxTool,
  FxToolContext,
  FxToolImage,
  FxToolResult,
  FxTools,
  FxTurnEvent,
  FxUsage,
  FxWasmModule,
  FxWasmSource,
  FxWorkspace,
  FxWorkspaceExecResult,
  FxXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libfx.cjs";

/** Options for `createFxEngine()` from `libfx/wasm`. */
export type FxWasmEngineOptions = FxEngineOptions & {
  /** The `fx-core.wasm` asset. */
  wasm: FxWasmSource;
};

/** Options for `createFxTerminal()` from `libfx/wasm`. */
export type FxWasmTerminalOptions = FxTerminalOptions & {
  /** The `fx-term.wasm` asset. */
  wasm: FxWasmSource;
};

/** One session on one fx core, with no durability of its own. Requires JSPI. */
export declare function createFxEngine(options: FxWasmEngineOptions): Promise<FxEngine>;

/** The interactive terminal harness on WebAssembly. Requires JSPI. */
export declare function createFxTerminal(options: FxWasmTerminalOptions): Promise<FxTerminal>;
