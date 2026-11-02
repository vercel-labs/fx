// `libfx` and `libfx/node` on Node.js, for `require` (node.cjs). The ESM entry,
// node.d.ts, re-exports this file: node.cjs is built from node.js.
import type {
  FxAgent,
  FxAgentOptions,
  FxBackendInfo,
  FxBackendInfoOptions,
  FxEngine,
  FxEngineOptions,
  FxNodeBackendOptions,
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
  wakeHandler,
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
  FxBackendAttempt,
  FxBackendChoice,
  FxBackendInfo,
  FxBackendInfoOptions,
  FxBackendReason,
  FxBackendReasonCode,
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
  FxHooks,
  FxHookEvent,
  FxHookMessage,
  FxHookToolCall,
  FxIdleResult,
  FxImageBlock,
  FxJsonSchema,
  FxKeyedTool,
  FxKeyEventLike,
  FxListModelsOptions,
  FxModelCatalogEntry,
  FxModelChoice,
  FxModelOptions,
  FxNodeBackendOptions,
  FxNodeWasmSource,
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
  FxSteerOptions,
  FxSteered,
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
  FxToolObservation,
  FxWaitRequest,
  FxWaitResponse,
  FxToolImage,
  FxToolResult,
  FxTools,
  FxTurn,
  FxTurnEvent,
  FxTurnResult,
  FxTurnView,
  FxUsage,
  FxWasmModule,
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

/** Options for `createFxAgent()` on Node.js. */
export type FxNodeAgentOptions = FxAgentOptions & FxNodeBackendOptions;

/** Options for `createFxEngine()` on Node.js. */
export type FxNodeEngineOptions = FxEngineOptions & FxNodeBackendOptions;

/** Options for `createFxTerminal()` on Node.js. */
export type FxNodeTerminalOptions = FxTerminalOptions & FxNodeBackendOptions;

/**
 * An agent whose sessions survive crashes, timeouts, and redeployments. It
 * returns at once and does no I/O until a session runs a turn. Without
 * `durability`, sessions live in Vercel's World on Vercel and in local files
 * elsewhere.
 */
export declare function createFxAgent(options?: FxNodeAgentOptions): FxAgent;

/**
 * The kernel under `createFxAgent()`: one conversation, held in the memory of
 * the process that runs it. `apiKey` is required, and it resolves once its
 * backend has loaded.
 */
export declare function createFxEngine(options: FxNodeEngineOptions): Promise<FxEngine>;

/** The interactive terminal harness. */
export declare function createFxTerminal(options: FxNodeTerminalOptions): Promise<FxTerminal>;

/** Inspects backend availability without creating an agent or terminal. */
export declare function getBackendInfo(options?: FxBackendInfoOptions): Promise<FxBackendInfo>;

/** The version of the libfx agent API. */
export declare const libfxApiVersion: 3;
