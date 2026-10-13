// `libfx` in browsers and other non-Node hosts, and `libfx/browser` (browser.js).
import type {
  FxAgent,
  FxAgentOptions,
  FxBrowserBackendOptions,
  FxEngine,
  FxEngineOptions,
  FxTerminal,
  FxTerminalOptions,
} from "./libfx.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  FxFencedError,
  FxJournalVersionError,
  fxSdkApiVersion,
  listModels,
  memory,
  supportsJspi,
  xtermAdapter,
} from "./libfx.cjs";

export type {
  Durability,
  FxAccepted,
  FxAgent,
  FxAgentEvent,
  FxAgentHostTool,
  FxAgentKeyedTool,
  FxAgentOptions,
  FxAgentTool,
  FxAgentTools,
  FxApiKeyCredentials,
  FxBrowserBackendOptions,
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
  FxIdleResult,
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
  FxPromptOptions,
  FxProviderCredentials,
  FxProviderTool,
  FxResizedImage,
  FxResourceBlock,
  FxResumeOptions,
  FxResumeTurn,
  FxSession,
  FxSessionEvent,
  FxSessionImageBlock,
  FxSessionOptions,
  FxSessionPromptInput,
  FxSessionTurnEvent,
  FxSharedOptions,
  FxSteer,
  FxSteeringInput,
  FxStopReason,
  FxStreamLine,
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
  FxTurn,
  FxTurnEvent,
  FxTurnResult,
  FxTurnView,
  FxUsage,
  FxWasmModule,
  FxWasmSource,
  FxWorkspace,
  FxWorkspaceExecResult,
  FxXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryOptions,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libfx.cjs";

/** Options for `createFxAgent()` in browsers. */
export type FxBrowserAgentOptions = FxAgentOptions & FxBrowserBackendOptions;

/** Options for `createFxEngine()` in browsers. */
export type FxBrowserEngineOptions = FxEngineOptions & FxBrowserBackendOptions;

/** Options for `createFxTerminal()` in browsers. */
export type FxBrowserTerminalOptions = FxTerminalOptions & FxBrowserBackendOptions;

/**
 * An agent whose sessions live in this page unless `durability` says
 * otherwise. It returns at once and does no I/O until a session runs a turn.
 */
export declare function createFxAgent(options?: FxBrowserAgentOptions): FxAgent;

/** One fx session on WebAssembly, with no durability of its own. `apiKey` is required. */
export declare function createFxEngine(options: FxBrowserEngineOptions): Promise<FxEngine>;

/** The interactive terminal harness. Connect it to xterm.js with `xtermAdapter()`. */
export declare function createFxTerminal(options: FxBrowserTerminalOptions): Promise<FxTerminal>;

/** The version of the libfx agent API. */
export declare const libfxApiVersion: 3;
