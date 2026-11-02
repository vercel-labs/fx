// Declarations shared by every libfx entry point. This file is not an entry
// point: import from "libfx" or one of its subpaths. Each entry's own file
// re-exports the part of it that entry has at runtime.

export {};

// ---------------------------------------------------------------------------
// Basics

/** A value that survives `JSON.stringify()` and `JSON.parse()`. */
export type JsonValue = string | number | boolean | null | readonly JsonValue[] | JsonObject;

/** A JSON object. A key whose value is `undefined` is dropped when serialized. */
export type JsonObject = { readonly [key: string]: JsonValue | undefined };

/** A JSON Schema object, such as a tool's input schema. */
export type FxJsonSchema = { readonly [key: string]: any };

/** Bytes: an `ArrayBuffer`, a typed array such as `Uint8Array` or `Buffer`, or a `DataView`. */
export type FxBytes = ArrayBuffer | ArrayBufferView;

/** `WebAssembly.Module` where the host's TypeScript lib declares it, and `never` where it does not. */
export type FxWasmModule = typeof globalThis extends { WebAssembly: { Module: abstract new (...args: any[]) => infer Module } } ? Module : never;

/** The `fetch` libfx calls: always with a URL string and an init object. The global `fetch` fits. */
export type FxFetch = (input: string, init: RequestInit) => Promise<Response>;

/** An error as libfx reports it in results and events. */
export interface FxErrorSummary {
  name: string;
  message: string;
  code?: string | number;
}

// ---------------------------------------------------------------------------
// Models

/** A reasoning effort: `"default"` leaves the choice to the model; a named level requests that level. */
export type FxEffort = "default" | "low" | "medium" | "high" | "xhigh" | (string & {});

/** Model configuration: the model ID and model-specific options. */
export interface FxModelOptions {
  /** The model ID, such as `"anthropic/claude-haiku-4.5"`. */
  id: string;
  /** The reasoning effort, for models that advertise effort levels. A named level is validated at creation. */
  effort?: FxEffort;
  /** Enables the fast lane for models that advertise one. */
  fast?: boolean;
  /** Requests Ultra mode, the higher-cost service tier, for models whose metadata advertises it. Disables Fast. */
  ultrafast?: boolean;
}

/** A model option: a model object, or a model ID string with the deprecated top-level options. Top-level options cannot be mixed with a model object. */
export type FxModelChoice =
  | {
    /** The model ID and its options. */
    model: FxModelOptions;
    effort?: never;
    fast?: never;
    ultrafast?: never;
  }
  | {
    /** The model ID. On AI Gateway it defaults to fx's built-in model; Codex, Grok, and custom providers need one. */
    model?: string | undefined;
    /** @deprecated Use `model: { id, effort }`. */
    effort?: FxEffort;
    /** @deprecated Use `model: { id, fast }`. */
    fast?: boolean;
    /** @deprecated Use `model: { id, ultrafast }`. */
    ultrafast?: boolean;
  };

/** An entry from `https://ai-gateway.vercel.sh/coding-agent/v1/models`. */
export interface FxModelCatalogEntry {
  id: string;
  [key: string]: unknown;
}

/** Options for `listModels()`. */
export interface FxListModelsOptions {
  /** The AI Gateway credential. */
  apiKey: string;
  /** Replaces the global `fetch` for the catalog request. */
  fetch?: FxFetch;
}

// ---------------------------------------------------------------------------
// Prompt input

/** A text block. */
export interface FxTextBlock {
  type: "text";
  text: string;
}

/** A resource block: a URI with optional text, given directly or under `resource`. */
export type FxResourceBlock =
  | { type: "resource"; resource: { uri: string; text?: string } }
  | { type: "resource"; uri: string; text?: string };

/**
 * An image block: a `Blob` or `File` with a non-empty `type`, raw bytes or
 * canonical base64 with an explicit `mimeType`, or only a `sourceRef` that
 * names a host-owned original. The payload must be PNG, JPEG, GIF, or WebP.
 */
export type FxImageBlock =
  | { type: "image"; data: Blob; mimeType?: string; sourceRef?: string }
  | { type: "image"; data: string | FxBytes; mimeType: string; sourceRef?: string }
  | { type: "image"; data?: undefined; mimeType: string; sourceRef: string };

/** One prompt block. */
export type FxPromptBlock = FxTextBlock | FxImageBlock | FxResourceBlock;

/** Prompt input: a string, or text, image, and resource blocks. */
export type FxPromptInput = string | readonly FxPromptBlock[];

/** An image block in a durable session's prompt: base64 data, or only a `sourceRef`. */
export type FxSessionImageBlock =
  | { type: "image"; data: string; mimeType: string; sourceRef?: string }
  | { type: "image"; data?: undefined; mimeType: string; sourceRef: string };

/** A durable session's prompt input. Image data must be a base64 string, because the prompt is stored as JSON before it runs. */
export type FxSessionPromptInput = string | readonly (FxTextBlock | FxSessionImageBlock | FxResourceBlock)[];

/** Steering or follow-up input: a string or text blocks. */
export type FxSteeringInput = string | readonly FxTextBlock[];

/** What `resizeImage` returns: any bytes and their MIME type. */
export interface FxResizedImage {
  bytes: FxBytes;
  mimeType: string;
}

// ---------------------------------------------------------------------------
// Tools

/** What a tool's `execute()` receives beside its input. */
export interface FxToolContext {
  /** Aborts when the turn is cancelled. */
  signal: AbortSignal;
  /** The model's id for the call. It stays the same when the call runs again after a crash. */
  executionId: string;
  /** The session the call belongs to. */
  sessionId: string;
  /** The JSON passed as `context` to the `session()` call whose prompt or steer started the turn. */
  context?: JsonValue;
  /** Present when hooks are installed. Observe host-owned input waits and child engines. */
  observation?: FxToolObservation;
}

export interface FxWaitRequest {
  kind: "approval" | "question" | "mcp_form" | "mcp_url";
  externalId?: string | number;
  server?: string;
  prompt?: string;
  schemaJson?: string;
  questions?: { question: string; options?: { label: string; description?: string }[] }[];
}

export interface FxWaitResponse<T = unknown> {
  outcome: "accepted" | "denied" | "cancelled" | "failed" | "timed_out";
  answers?: string[];
  value?: T;
}

export interface FxToolObservation {
  /** Calls the host effect once and preserves its response/error. Never makes a permission decision. */
  wait<T>(request: FxWaitRequest, run: () => FxWaitResponse<T> | Promise<FxWaitResponse<T>>): Promise<FxWaitResponse<T>>;
  /** Used by the MCP adapter to bind a remote call to this tool invocation. */
  mcp<T>(identity: { server: string | null; tool: string; correlationId?: string | undefined }, run: (request: { correlationId: string | undefined }) => T | Promise<T>): Promise<T>;
  /** Install these hooks on a host-created child engine to retain the parent tool relationship. */
  childHooks(): FxHooks;
}

/** An image in a typed tool result: base64 `data`, or a `sourceRef` with no `data`. */
export type FxToolImage =
  | { type: "image"; mimeType: string; data: string; sourceRef?: string }
  | { type: "image"; mimeType: string; data?: undefined; sourceRef: string };

/** A typed tool result that returns rich image content. Ordinary values returned by tools are JSON text. */
export interface FxToolResult {
  type: "libfx.tool-result";
  text: string;
  /** Up to 8 images. */
  images: readonly FxToolImage[];
  /** Reports the result as a tool error. */
  isError?: boolean;
}

/** A tool the JavaScript host runs. */
export interface FxHostTool<Input = any> {
  /** 1 to 64 letters, digits, `_`, or `-`. */
  name: string;
  description: string;
  /** A JSON Schema object for the tool's input. */
  inputSchema: FxJsonSchema;
  /** Runs one call. A string is sent as is, an `FxToolResult` as rich content, and any other value as JSON text. */
  execute: (input: Input, context: FxToolContext) => unknown;
  /** Running a call twice is safe, so a call cut off by a crash runs again. Default `false`. */
  idempotent?: boolean;
  /** Calls must not overlap others: one starts after every earlier call in the response finishes. Defaults to `!idempotent`. */
  writes?: boolean;
  providerExecuted?: false;
}

/** A tool the JavaScript host runs for `createFxAgent()`, which must say whether a call is safe to run twice. */
export interface FxAgentHostTool<Input = any> extends FxHostTool<Input> {
  /** `true` when running a call twice is harmless, `false` when it is not. Required. */
  idempotent: boolean;
}

/** A tool the provider runs, such as Gateway web search. `web_search` is currently the supported name. */
export interface FxProviderTool {
  name: "web_search";
  providerExecuted: true;
  execute?: never;
}

/** A tool descriptor. */
export type FxTool = FxHostTool | FxProviderTool;

/** A tool descriptor in an object keyed by tool name. A descriptor that includes `name` must match its key. */
export type FxKeyedTool =
  | (Omit<FxHostTool, "name"> & { name?: string })
  | (Omit<FxProviderTool, "name"> & { name?: "web_search" });

/** Tools: an array of descriptors, or an object keyed by tool name. */
export type FxTools = readonly FxTool[] | { readonly [name: string]: FxKeyedTool };

/** A tool descriptor for `createFxAgent()`. */
export type FxAgentTool = FxAgentHostTool | FxProviderTool;

/** A `createFxAgent()` tool descriptor in an object keyed by tool name. */
export type FxAgentKeyedTool =
  | (Omit<FxAgentHostTool, "name"> & { name?: string })
  | (Omit<FxProviderTool, "name"> & { name?: "web_search" });

/** `createFxAgent()` tools: an array of descriptors, or an object keyed by tool name. */
export type FxAgentTools = readonly FxAgentTool[] | { readonly [name: string]: FxAgentKeyedTool };

// ---------------------------------------------------------------------------
// Turn events and results

/** A model or tool event of a turn. */
export type FxTurnEvent =
  | { type: "text_delta"; delta: string }
  | { type: "reasoning_delta"; delta: string }
  /** Steering entering the turn as its model request carries it; `id` is the steer's id. */
  | { type: "user_message"; text: string; id?: string }
  | { type: "tool_start"; id: string; name: string; input?: JsonValue; inputTruncated?: undefined; inputPreview?: undefined }
  /** A tool input over 64 KiB of JSON arrives as a prefix. The tool still receives complete arguments. */
  | { type: "tool_start"; id: string; name: string; input?: undefined; inputTruncated: true; inputPreview: string }
  | { type: "tool_end"; id: string; name: string; content?: string; isError: boolean };

/** Token usage. Each count is present when the provider reported it. */
export interface FxUsage {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  reasoningTokens?: number;
}

/** Why an engine turn ended. */
export type FxStopReason = "end_turn" | "max_output_tokens" | "max_model_turns" | "refused" | "cancelled";

// ---------------------------------------------------------------------------
// Diagnostics

interface FxEventBase {
  /** `performance.now()` when the event was emitted. */
  timestamp: number;
}

/** The libfx version, tool set, and model a checkpoint records. */
export interface FxCheckpointMeta {
  libfxVersion: string;
  toolSchemaHash: string;
  model: string;
}

/** A runtime diagnostic an engine passes to `onEvent`, separate from model output. */
export type FxEngineEvent = FxEventBase & (
  | { type: "runtime.start" }
  | { type: "runtime.ready" }
  | { type: "runtime.exit"; code: number }
  | { type: "acp.send"; message: unknown }
  | { type: "acp.receive"; message: unknown }
  | { type: "transport.start"; attempt: number; method: string; endpoint: string; model: string | undefined }
  | {
    type: "transport.response";
    attempt: number;
    status: number;
    elapsedMs: number;
    requestId: string | null;
    generationId: string | null;
    model: string | undefined;
    provider: string | null;
  }
  | { type: "transport.error"; attempt: number; elapsedMs: number; error: string }
  | { type: "transport.retry"; attempt: number; nextAttempt: number; elapsedMs: number; error: string }
  /** Liveness while a response body streams, at most once per 250 ms. */
  | { type: "transport.activity"; attempt: number; chunkBytes: number; totalBytes: number }
  | { type: "permission.request"; request: unknown }
  | { type: "permission.resolve"; optionId: unknown }
  | { type: "journal.open"; events: number; checkpoint: boolean; turns: unknown; resumable: boolean }
  | { type: "journal.append"; events: number }
  | { type: "journal.error"; error: string }
  | { type: "checkpoint.save"; through: string; bytes: number }
  | { type: "checkpoint.error"; error: string; message: string }
  /** A checkpoint saved under a different libfx version, tool set, or model still loaded. */
  | { type: "checkpoint.mismatch"; sessionId: string; changed: Array<keyof FxCheckpointMeta>; saved: unknown; current: FxCheckpointMeta }
  | { type: "output.backpressure"; bufferedBytes: number; bufferedEvents: number }
  | { type: "output.discarded"; reason: "cancelled"; bytes: number }
);

/** A durable session's diagnostic: a failed write or engine, a takeover, or a function deadline. */
export type FxSessionEvent = FxEventBase & (
  | { type: "session.error"; sessionId: string; error: FxErrorSummary }
  | { type: "session.fenced"; sessionId: string; epoch: number }
  /** A message for a session of the agent `agent` reached this one, which sent it on. */
  | { type: "session.forwarded"; sessionId: string; agent: string }
  /** A queue delivery named an input the session's log does not hold, or none at all, so it ran nothing. */
  | { type: "session.refused"; sessionId?: string; messageId?: string; reason: "unknown message" | "malformed message" }
  /** `cutoffs`: the times in a row the deadline cut off the same step, this one included. */
  | { type: "session.deadline"; sessionId: string; epoch: number; cutoffs: number }
  | { type: "ui.error"; sessionId: string; error: string }
);

/** What an agent passes to `onEvent`: its engines' diagnostics and its sessions'. */
export type FxAgentEvent = FxEngineEvent | FxSessionEvent;

// ---------------------------------------------------------------------------
// Options shared by agents and engines

/** Semantic observation, independent of diagnostics, UI events, permissions, and tracing libraries. */
export interface FxHooks {
  /** Parent of a host-created child engine. Normally supplied by `context.observation.childHooks()`. */
  parent?: { rootSessionId: string; sessionId: string; turnId: string; callId: string };
  /** Include bounded messages, instructions, tool arguments/results, and schemas. Default false. */
  captureContent?: boolean;
  /** Called in event order, but returned promises are not awaited. The host owns buffering and flushing. */
  onEvent(event: FxHookEvent): void | Promise<void>;
  /** Receives callback throws and rejected promises. Errors here are contained too. */
  onError?(error: unknown): void | Promise<void>;
}

/** An authoritative model call identity, with no provider replay or credentials. */
export interface FxHookToolCall {
  callId: string;
  name: string;
  provenance: "fx_local" | "provider_executed";
  /** Present only with content capture. May be a truncated JSON string. */
  argumentsJson?: string | null;
}

export interface FxHookMessage {
  role: "system" | "user" | "assistant" | "tool";
  content?: string | null;
  toolCallId: string | null;
  toolName: string | null;
  toolResultStatus: "success" | "failure" | null;
  imageCount: number;
  toolCalls: FxHookToolCall[];
}

interface FxHookEnvelope {
  version: 1;
  sessionId: string;
  rootSessionId: string;
  parentSessionId: string | null;
  sourceSessionId: string | null;
  workId: string | null;
  parentTurnId?: string;
  parentCallId?: string;
  /** Stable host turn ID; null for session-scoped journal receipts. */
  turnId: string | null;
  /** Fresh for each execution/resume, not a trace or durable operation ID. */
  executionId: string | null;
  /** One-based within this execution, or 0 outside a step. */
  stepIndex: number;
  /** Milliseconds since the epoch, sampled at the semantic boundary. */
  timestamp: number;
  contentCaptured: boolean;
  /** A content budget or collection limit omitted information. */
  contentTruncated: boolean;
}

/** Versioned execution facts. The host chooses topology, conventions, redaction, and export. */
export type FxHookEvent = FxHookEnvelope & (
  | { type: "turn.start"; data: { resumed: boolean; input?: string | null } }
  | { type: "turn.end"; data: { outcome: "completed" | "interrupted" | "failed" | "paused" | "yielded" | "cancelled" | "fenced"; error: string | null; handoff?: boolean } }
  | { type: "step.start" | "step.end"; data: Record<string, never> }
  | { type: "model.start"; data: {
    /** Scoped to executionId. Retries have distinct IDs. */
    modelCallId: number;
    parentCallId: string | null;
    purpose: "agent" | "compaction" | "vision" | "title" | "permission_review" | "auxiliary";
    model: string; toolChoice: string; maxOutputTokens: number | null; messageCount: number;
    instructions?: FxHookMessage[]; messages?: FxHookMessage[];
    toolsJson?: string | null;
    tools: { name: string; description?: string | null; inputSchemaJson?: string | null }[];
  } }
  | { type: "model.admitted" | "model.output_start"; data: { modelCallId: number } }
  | { type: "model.end"; data: {
    modelCallId: number; error: string | null; cancelled: boolean; output?: string | null;
    finishReason?: string | null; generationId?: string | null; provider?: string | null;
    usage?: { inputTokens: number | null; outputTokens: number | null; cacheReadTokens: number | null; cacheWriteTokens: number | null; reasoningTokens: number | null };
    toolCalls?: FxHookToolCall[];
  } }
  | { type: "tool.start"; data: { call: FxHookToolCall; rerun: boolean } }
  | { type: "permission.start"; data: { call: FxHookToolCall } }
  | { type: "tool.end"; data: {
    call: FxHookToolCall; output?: string | null; status: "success" | "failure" | "cancelled"; error: string | null;
    usage?: { inputTokens: number; outputTokens: number; webSearchRequests: number };
  } }
  /** Acceptance into conversation memory, not proof of durable storage. */
  | { type: "tool.result"; data: { call: FxHookToolCall; output?: string | null; status: "success" | "failure" } }
  /** Permission evaluation can complete without a human prompt. */
  | { type: "permission.end"; data: { call: FxHookToolCall; decision: "once" | "always" | "deny" | "policy_denied" | "permission_required" | null; error: string | null } }
  | { type: "wait.start"; data: { requestId: number | string; kind: FxWaitRequest["kind"]; callId: string | null; externalId: string | number | null; server: string | null; prompt?: string | null; schemaJson?: string | null; questionCount: number; questions?: { question: string; submission?: "none" | "input" | "choice"; options: { label: string; description?: string | null }[] }[] } }
  | { type: "wait.end"; data: { requestId: number | string; outcome: FxWaitResponse["outcome"]; error: string | null; answers?: string[] } }
  | { type: "mcp.start"; data: { operationId: number | string; callId: string | null; server: string | null; tool: string; transport: string | null } }
  | { type: "mcp.request"; data: { operationId: number | string; requestId: number | string; requestIdKind: "jsonrpc" | "engine" | "correlation" } }
  | { type: "mcp.end"; data: { operationId: number | string; status: "success" | "failure" | "cancelled" | "input_required" | "unavailable" | "unknown"; error: string | null } }
  | { type: "delegation"; data: { callId: string; childSessionId: string; workId: string; operationId: string | null; phase: "dispatched" | "completed" | "yielded" | "replayed" | "failed" | "cancelled" | "feedback_queued" | "feedback_applied" | "feedback_not_applied" } }
  /** Emitted only after append resolves and its cursor validates. */
  | { type: "journal.commit"; data: { cursor: string; firstSeq: number | null; lastSeq: number | null; eventCount: number } }
  | { type: "journal.restore"; data: { cursor: string | null; lastSeq: number; resumable: boolean; openTurnId: string | null; lastTurnId: string | null } }
  | { type: "journal.error"; data: { error: string; fenced: boolean } }
);

/** Options `createFxAgent()` and `createFxEngine()` share. */
export interface FxSharedOptions<Event> {
  /** Host-owned instrumentation of native and Wasm execution. Disabled by default. */
  hooks?: FxHooks;
  /** The complete host-owned system context, up to 64 KiB of UTF-8. An array is joined with blank lines. */
  instructions?: string | readonly string[];
  tools?: FxTools;
  /** Replaces the global `fetch` for model and catalog requests. */
  fetch?: FxFetch;
  /** The Gateway model catalog, as the response's `{ data }` or the entries alone, so the agent makes no catalog request. */
  modelCatalog?: readonly FxModelCatalogEntry[] | { readonly data: readonly FxModelCatalogEntry[] };
  /** Downscales or converts prompt images before they are sent. */
  resizeImage?: (image: { bytes: Uint8Array; mimeType: string }) => FxResizedImage | Promise<FxResizedImage>;
  /** Trusted host configuration: the canonical Gateway or an explicit loopback HTTP URL. */
  gatewayChatUrl?: string;
  /** Receives runtime diagnostics separately from model output. */
  onEvent?: (event: Event) => void;
}

/** Where a Node.js factory's backend comes from. */
export type FxBackendChoice = "auto" | "native" | "wasm";

/** A Wasm asset in browsers and on `libfx/wasm`: a URL string, a `Response`, bytes, a compiled module, or a promise of one of the last three. */
export type FxWasmSource = string | Response | FxBytes | FxWasmModule | Promise<Response | FxBytes | FxWasmModule>;

/** A Wasm asset on Node.js: a path, a URL, a `Response`, bytes, a compiled module, or a promise of an HTTP(S) URL string, a `Response`, bytes, or a module. */
export type FxNodeWasmSource = string | URL | Response | FxBytes | FxWasmModule | Promise<string | Response | FxBytes | FxWasmModule>;

/** Backend selection on Node.js. */
export interface FxNodeBackendOptions {
  /** `"auto"` tries the native addon, then Wasm; `"native"` requires N-API; `"wasm"` requires Wasm and JSPI. */
  backend?: FxBackendChoice;
  /** Trusted host configuration: the native addon module, its path or URL, or `false` to disable native loading. */
  nativeAddon?: string | URL | false | object;
  /** The Wasm asset to use instead of the packaged one. */
  wasm?: FxNodeWasmSource;
}

/** Wasm asset selection in browsers. */
export interface FxBrowserBackendOptions {
  /** The Wasm asset to use instead of the packaged one. */
  wasm?: FxWasmSource;
}

// ---------------------------------------------------------------------------
// Persistence

/** One stored record of a session's journal. */
export interface JournalRecord {
  cursor: string;
  data: Uint8Array;
}

/** What `Persistence.load()` resolves to: the latest checkpoint, if any, and the records stored after it, oldest first. */
export interface PersistenceLoadResult {
  checkpoint?: { data: FxBytes; through: string };
  journal?: Iterable<{ cursor: string; data: FxBytes }> | AsyncIterable<{ cursor: string; data: FxBytes }>;
  /** The cursor the next `append()` names as `expected`, for a store whose log holds entries of its own after the last record. Defaults to the last record's cursor, or the checkpoint's `through`. */
  head?: string | null;
}

/** What one record tells a store that set `marks: true` about turns: a turn started, ended or yielded, or an input was accepted. Other marks may appear; a store keeps or ignores them. */
export type FxJournalMark =
  | { start: string }
  | { end: true }
  | { yield: true }
  | { accepted: string }
  | { step: string };

/** A store for one session's records and checkpoints. libfx writes opaque bytes; the store never parses them. */
export interface Persistence {
  /** Called once by `createFxEngine()`. Resolve to `{}` for a session with nothing stored. */
  load(): Promise<PersistenceLoadResult>;
  /**
   * Stores one record and resolves to its cursor. Reject with an `FxFencedError` when `expected` is not the last stored record's cursor.
   * `barrier` is true when libfx waits for the record before it goes on, such as before a tool call with effects. A store may resolve a record with `barrier: false` before it is durable, if it keeps records in order and resolves one with `barrier: true` only once it and every record before it are durable.
   */
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array; barrier: boolean; marks?: FxJournalMark[] }): Promise<{ cursor: string }>;
  /** Stores a checkpoint covering the records through `through`. */
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>;
  /** Set to receive each record's `marks`, for a store that tracks turns and accepted inputs without reading records. */
  marks?: boolean;
}

/** The persistence store `createMemoryPersistence()` returns. */
export interface MemoryPersistence extends Persistence {
  /** The stored records, oldest first. */
  readonly records: Array<JournalRecord & { idempotencyKey: string }>;
  /** The latest checkpoint, or null. */
  readonly checkpoint: { through: string; data: Uint8Array } | null;
  load(): Promise<{ checkpoint?: { data: Uint8Array; through: string }; journal: JournalRecord[] }>;
  saveCheckpoint(input: { through: string; data: Uint8Array }): Promise<void>;
}

/** Another writer took over the session after this agent loaded it. Its `code` is `FX_FENCED`. */
export declare class FxFencedError extends Error {
  constructor(message?: string);
  name: "FxFencedError";
  code: "FX_FENCED";
}

/** The journal, or the `checkpoint` option, was written by a newer libfx than this one. Its `code` is `FX_JOURNAL_VERSION`. */
export declare class FxJournalVersionError extends Error {
  constructor(message?: string);
  name: "FxJournalVersionError";
  code: "FX_JOURNAL_VERSION";
}

/** A persistence store that keeps the records and the latest checkpoint in memory, for tests and hosts that copy them to their own storage. */
export declare function createMemoryPersistence(): MemoryPersistence;

// ---------------------------------------------------------------------------
// A single engine

/** Called once for each call a resumed turn left running. Return `"rerun"` to run it again under the same `executionId`. */
export type FxOnAmbiguous = (call: { executionId: string; name: string; input: unknown }) => "rerun" | undefined | void;

/** Options for an engine's `prompt()`. */
export interface FxEnginePromptOptions {
  /** Cancels the turn when it aborts. */
  signal?: AbortSignal;
  /** The turn's id, so a retried prompt continues or answers the same turn. 1 to 128 letters, digits, `.`, `_`, or `-`. */
  turnId?: string;
  onAmbiguous?: FxOnAmbiguous;
  /** With `persistence`: a time, in milliseconds since the epoch, after which the turn stops before its next model request with the stop reason `yielded`. The journal keeps it open, and the next `resume()` continues it without telling the model it was interrupted. */
  yieldAt?: number;
}

/** Options for an engine's `resume()`. */
export interface FxResumeOptions {
  signal?: AbortSignal;
  onAmbiguous?: FxOnAmbiguous;
  /** As `FxEnginePromptOptions.yieldAt`. */
  yieldAt?: number;
}

/** How an engine turn ended. */
export interface FxEngineTurnResult {
  stopReason: FxStopReason;
  usage: FxUsage;
}

/** A steer: resolves to `{ id }` once accepted, and carries the same `id` at once. */
export type FxSteer = Promise<{ id: string; withdrawn?: true }> & { readonly id: string };

/** One engine turn: an async iterable of its events with one consumer. Breaking out of the iterator cancels the turn. */
export interface FxEngineTurn {
  /** The turn's id. */
  readonly id: string | null;
  readonly result: Promise<FxEngineTurnResult>;
  /** Stops the turn. `{ reason: "handoff" }` stores nothing more, so the next agent continues it; it needs persistence. */
  cancel(options?: { reason?: "handoff" }): void;
  /** Appends guidance at the next safe model boundary. */
  steer(input: FxSteeringInput, id?: string): FxSteer;
  /** Takes a steer back before the model sees it. */
  withdraw(id: string): Promise<"withdrawn" | "already_placed">;
  [Symbol.asyncIterator](): AsyncIterator<FxTurnEvent>;
}

/** A follow-up: a promise for its turn that carries its `id` and `accepted`, which resolves `{ id }` once it is stored. */
export type FxFollowUp = Promise<FxEngineTurn> & { readonly id: string; readonly accepted: Promise<{ id: string }> };

/** One conversation held in the memory of the process that runs it, with no queue and no session store. */
export interface FxEngine {
  /** The id the engine uses for AI Gateway session affinity and prompt caching. */
  readonly sessionId: string;
  /** Starts a turn. Only one top-level prompt may run at a time. */
  prompt(input: FxPromptInput, options?: FxEnginePromptOptions): FxEngineTurn;
  /** Continues the turn the last process left open, or the next held follow-up; null when there is none. */
  resume(options?: FxResumeOptions): FxEngineTurn | null;
  /** Queues text to run as its own turn once the current turn ends, or at once when none is running. */
  followUp(input: FxSteeringInput): FxFollowUp;
  /** The conversation as opaque, bounded, versioned bytes, when no prompt is running. */
  checkpoint(): Promise<Uint8Array>;
  close(): Promise<void>;
}

/** Where an engine keeps its conversation: a persistence store, or a checkpoint to start from. The two cannot be combined. */
export type FxEngineStorage =
  | {
    /** Records the session as it runs, so a new engine can continue it. */
    persistence: Persistence;
    /** Record bytes since the last checkpoint after which a checkpoint is saved. Default 1 MiB. */
    checkpointAfterBytes?: number;
    checkpoint?: undefined;
  }
  | {
    persistence?: undefined;
    checkpointAfterBytes?: undefined;
    /** Checkpoint bytes to restore. */
    checkpoint?: FxBytes;
  };

/** A subscription provider's credentials: a ChatGPT plan's for Codex, or a Grok plan's. `accountId` and `expiresAt` default to the access token's own claims when it carries them. */
export interface FxProviderCredentials {
  accessToken: string;
  /** Lets libfx refresh the access token near expiry and once after a rejection. */
  refreshToken?: string;
  accountId?: string;
  /** Milliseconds since the epoch. */
  expiresAt?: number;
}

/** Runs on AI Gateway, the default. */
export interface FxGatewayProvider {
  provider?: "gateway" | undefined;
  credentials?: undefined;
  onCredentials?: undefined;
  refreshLock?: undefined;
}

/** Runs on a user's plan instead of AI Gateway. */
interface FxSubscriptionProvider<Provider extends "codex" | "grok"> {
  provider: Provider;
  /** Credentials for the provider's requests, asked for in whichever process runs the turn. `sessionId` is set for model requests and absent for the model list. */
  credentials: (request: { provider: Provider; sessionId?: string }) => FxProviderCredentials | Promise<FxProviderCredentials>;
  /** Receives credentials libfx refreshed, so the host can save them. */
  onCredentials?: (credentials: FxProviderCredentials, info: { provider: Provider; sessionId?: string }) => void | Promise<void>;
  /**
   * Runs `refresh` while the host holds a lock on the account, so a host with
   * several servers refreshes it on one at a time. libfx asks `credentials()`
   * again inside it and uses credentials another server already saved.
   */
  refreshLock?: (info: { provider: Provider; sessionId?: string }, refresh: () => Promise<void>) => Promise<unknown>;
}

/** Runs on a ChatGPT plan through Codex instead of AI Gateway. */
export type FxCodexProvider = FxSubscriptionProvider<"codex">;

/** Runs on a Grok plan instead of AI Gateway. */
export type FxGrokProvider = FxSubscriptionProvider<"grok">;

/** What libfx knows about a model a custom provider serves. Unset fields are unknown. */
export interface FxCustomProviderModel {
  contextWindow?: number;
  /** Less than `contextWindow` when both are set. */
  maxOutputTokens?: number;
  supportsToolUse?: boolean;
  supportsVision?: boolean;
}

/** A server that speaks OpenAI Chat Completions, such as a local model server or a router. */
export interface FxCustomProviderDefinition {
  /** Names the provider to `credentials()`: a letter, then letters, digits, `_` or `-`, at most 64 characters. Not `gateway`, `codex` or `grok`. */
  name: string;
  /** The API prefix: requests go to `{baseUrl}/chat/completions`. HTTPS, or HTTP on localhost. */
  baseUrl: string;
  /** The models it serves, by id. */
  models?: Record<string, FxCustomProviderModel>;
}

/** A custom provider's API key. */
export interface FxApiKeyCredentials {
  apiKey: string;
}

/** Runs on a custom provider instead of AI Gateway. */
export interface FxCustomProvider {
  provider: FxCustomProviderDefinition;
  /** The API key for the provider's requests, asked for in whichever process runs the turn. Omit it for a server that needs no key. */
  credentials?: ((request: { provider: string; sessionId?: string }) => FxApiKeyCredentials | Promise<FxApiKeyCredentials>) | undefined;
  onCredentials?: undefined;
  refreshLock?: undefined;
}

/** Options for `createFxEngine()`. */
export type FxEngineOptions = FxSharedOptions<FxEngineEvent> & FxModelChoice & FxEngineStorage & (
  | (FxGatewayProvider & {
    /** The AI Gateway credential. Required. */
    apiKey: string;
  })
  | ((FxCodexProvider | FxGrokProvider | FxCustomProvider) & {
    /** The AI Gateway credential, unused by this provider's turns. */
    apiKey?: string | undefined;
    /** The provider's own model. Required: fx's built-in model is an AI Gateway id. */
    model: string | FxModelOptions;
  })
) & {
  /** The id for AI Gateway session affinity: 1 to 255 letters, digits, `.`, `_`, or `-`. Give a restored session the id it had before. */
  sessionId?: string | null;
};

// ---------------------------------------------------------------------------
// Durability

declare const durabilityBrand: unique symbol;

/** Where an agent's sessions live: `memory()`, or `local()`, `vercel()`, or `world()`. */
export interface Durability {
  readonly [durabilityBrand]: true;
}

/** Options for `memory()`. */
export interface MemoryOptions {
  /** Each delivery runs as if its function stopped after this long. No limit by default. */
  maxDurationMs?: number;
  /** How long before the deadline each delivery stops. Default 30000. */
  reserveMs?: number;
}

/** The durability that keeps sessions in this process only. Nothing survives the process. */
export declare function memory(options?: MemoryOptions): Durability;

// ---------------------------------------------------------------------------
// Durable agents

/** Options for `createFxAgent()`. */
export type FxAgentOptions = Omit<FxSharedOptions<FxAgentEvent>, "tools"> & FxModelChoice & (FxGatewayProvider | FxCodexProvider | FxGrokProvider | FxCustomProvider) & {
  /** Every host tool sets `idempotent`. */
  tools?: FxAgentTools;
  /** The AI Gateway credential. Without it, libfx uses `AI_GATEWAY_API_KEY`, then on Vercel the deployment's OIDC token. */
  apiKey?: string | undefined;
  /** Where sessions live. Without it, libfx picks one from the environment. */
  durability?: Durability | undefined;
  /** Checkpoint bytes the agent's new sessions start from. */
  checkpoint?: FxBytes;
  /**
   * The agent's name, 1 to 64 letters, digits, `.`, `_` or `-`, starting with a letter or digit. Default `"default"`.
   * A session's turns run only on agents with the name of the agent that created it, so an app can have several
   * durable agents. Agents with the same name are copies of one agent and share its sessions' turns.
   */
  name?: string;
};

/** Options for `agent.session()`. Each applies to the turns this session object starts. */
export interface FxSessionOptions {
  /** JSON every tool call of those turns receives as `context`, copied when `session()` is called. */
  context?: JsonValue;
  /** The model for those turns instead of the agent's whole model choice: a model ID, or a model object. */
  model?: string | FxModelOptions;
  /** The system context for those turns instead of the agent's. An array is joined with blank lines. */
  instructions?: string | readonly string[];
}

/** Options for a durable session's `prompt()`. */
export interface FxPromptOptions {
  /** The turn's id, so a retried request reaches the same turn. Follows the session id rule. */
  messageId?: string;
  /** Cancels this prompt's turn when it aborts, whether it runs or still waits, and never a later turn. */
  signal?: AbortSignal;
}

/** Options for a durable session's `steer()`. */
export interface FxSteerOptions {
  /**
   * The steer's id, so a retried request adds nothing. Follows the session id rule. Reusing a prompt's id rejects
   * with `FX_MESSAGE_ID_IN_USE`.
   */
  messageId?: string;
}

/** What a durable session's `steer()` resolves to once the steer is stored. */
export interface FxSteered {
  /** The steer's id. Its `user_message` event carries it as `id` when it joins a turn, and its own turn's events carry it as `messageId`. */
  messageId: string;
}

/** What `turn.accepted` resolves to once the prompt is stored. */
export interface FxAccepted {
  messageId: string;
  sessionId: string;
}

/** How a durable turn ended. */
export interface FxTurnResult {
  messageId: string;
  /** `error` when the turn failed, with the reason in `error`; `unknown` when the process that ran it stopped before writing how it ended. */
  stopReason: FxStopReason | "error" | "unknown";
  /** Absent when the result is a failure read from the session's log rather than from the turn's end. */
  usage?: FxUsage;
  error?: FxErrorSummary;
  /** The lease epoch of the worker that wrote the turn's end. */
  epoch?: number;
  /** Set when a `prompt()` with an already accepted `messageId` reports that turn's outcome. */
  repeated?: true;
}

/** What `session.resume()` resolves to when no turn was left open. */
export interface FxIdleResult {
  stopReason: "idle";
  usage: FxUsage;
}

/** A turn event as a durable session delivers it, with the lease epoch of the worker that wrote it. */
export type FxSessionTurnEvent = FxTurnEvent & { epoch?: number };

/** A view of one durable turn. It reads the session stream only once its events, `readable` or `result` are used. Dropping it cancels nothing; call `session.cancel()` to stop the turn. */
export interface FxTurnView<Result> {
  /** Resolves once the prompt is stored, or at once for a prompt whose signal had already aborted. */
  readonly accepted: Promise<FxAccepted>;
  /** Resolves when the turn ends. */
  readonly result: Promise<Result>;
  /** The same turn as an NDJSON stream a route can return as its response body. Each line is an `FxStreamLine`. */
  readonly readable: ReadableStream<Uint8Array>;
  [Symbol.asyncIterator](): AsyncIterator<FxSessionTurnEvent>;
}

/** A view of a prompted turn. */
export interface FxTurn extends FxTurnView<FxTurnResult> {
  /** The turn's id, which libfx chooses unless the prompt passed one. */
  readonly messageId: string;
}

/** A view of the turn `session.resume()` continues. `accepted` carries the resume request's id. */
export interface FxResumeTurn extends FxTurnView<FxTurnResult | FxIdleResult> {
  /** The continued turn's id, once known. */
  readonly messageId: string | null;
}

/** One line of `session.stream()` or `turn.readable`, parsed from NDJSON. */
export type FxStreamLine = (
  | (FxTurnEvent & { messageId: string })
  | { type: "turn_start"; messageId: string; sessionId: string; input?: string }
  | { type: "turn_resume"; messageId: string; sessionId: string }
  | { type: "turn_yield"; messageId: string }
  | {
    type: "turn_end";
    messageId: string;
    stopReason: FxStopReason | "error" | "unknown";
    usage?: FxUsage;
    error?: FxErrorSummary;
    repeated?: true;
  }
  | { type: "idle"; requestId: string }
) & {
  /** The lease epoch of the line's writer. Readers hide a line whose epoch is lower than one before it. */
  epoch?: number;
  /** The position `stream()` resumes after. Present on every line of `stream()`; a turn view's `readable` omits it from the `turn_end` of a turn that had already ended. */
  cursor?: number;
};

/** One durable conversation. Opening a session reads nothing; its first prompt does. */
export interface FxSession {
  /** The session's id; for a new session, null until its first prompt is accepted. */
  readonly id: string | null;
  /**
   * Queues `input` as the session's next turn and returns a view of that turn. Throws a
   * TypeError or RangeError for an input libfx refuses, and stores nothing. A prompt whose
   * `signal` aborts before it is stored is never stored, and ends `cancelled`.
   */
  prompt(input: FxSessionPromptInput, options?: FxPromptOptions): FxTurn;
  /** Continues a turn a stopped process left open; its result has the stop reason `idle` when there was none. */
  resume(): FxResumeTurn;
  /** Every event the session has produced from `cursor` on, as NDJSON, staying open for the events after them. */
  stream(cursor?: number): ReadableStream<Uint8Array>;
  /**
   * Steers the running turn the way the fx CLI does: it cuts a streaming reply short, waits for a running tool, and
   * joins a turn waiting to start. When no turn runs or waits, it starts one. A steer with images or resources cannot
   * join a turn: the running one ends at its next safe point and the steer runs next.
   */
  steer(input: FxSessionPromptInput, options?: FxSteerOptions): Promise<FxSteered>;
  /** Cancels the running turn. */
  cancel(): Promise<void>;
  /** The session's history as opaque bytes, read without changing the session. */
  checkpoint(): Promise<Uint8Array>;
}

/** An agent: the configuration its sessions run under. Create one per server and open a session per conversation. */
export interface FxAgent {
  /** The agent's name, `"default"` unless `createFxAgent()` gave one. */
  readonly name: string;
  /** Opens the session `id`, or starts a new one without it. Any other value, `null` included, throws. */
  session(id?: string, options?: FxSessionOptions): FxSession;
  /** An id for a new session, before its first prompt. */
  newSessionId(): Promise<string>;
  /** The id of the session `agent.prompt()` uses, once known. */
  readonly sessionId: string | null;
  /** Prompts a session the agent opens for itself, for code that holds one conversation. */
  prompt(input: FxSessionPromptInput, options?: FxPromptOptions): FxTurn;
  /** The history of the session `agent.prompt()` uses, as opaque bytes. */
  checkpoint(): Promise<Uint8Array>;
  /** The request handler a deployment mounts for queue deliveries; it delivers to whichever agent in the process a message names. */
  wakeHandler(): (request: Request) => Promise<Response>;
  /** Waits for the turns this process is running, then lets their sessions go. */
  close(): Promise<void>;
}

/**
 * The request handler a deployment mounts for queue deliveries, for every durable agent in the process: each
 * delivery goes to the agent its message names. One route and one queue trigger serve any number of agents.
 */
export declare function wakeHandler(): (request: Request) => Promise<Response>;

// ---------------------------------------------------------------------------
// Backend diagnostics (Node.js)

/** A stable backend diagnostic code. */
export type FxBackendReasonCode =
  | "LIBFX_UNSUPPORTED_PLATFORM"
  | "LIBFX_NATIVE_ARTIFACT_MISSING"
  | "LIBFX_NATIVE_LOAD_FAILED"
  | "LIBFX_NATIVE_API_MISMATCH"
  | "LIBFX_NATIVE_SURFACE_MISSING"
  | "LIBFX_NATIVE_DISABLED"
  | "LIBFX_JSPI_UNAVAILABLE"
  | "LIBFX_WASM_LOAD_FAILED";

/** Why a backend was unavailable. `causeCode` retains a Node error code such as `ENOENT` when one exists. */
export interface FxBackendReason {
  code: FxBackendReasonCode;
  message: string;
  causeCode?: string | number;
}

/** One backend `getBackendInfo()` tried. */
export type FxBackendAttempt =
  | { backend: "native" | "wasm-jspi"; available: true; reason: null }
  | { backend: "native" | "wasm-jspi"; available: false; reason: FxBackendReason };

/** Options for `getBackendInfo()`. */
export interface FxBackendInfoOptions {
  /** `"agent"` by default. */
  surface?: "agent" | "terminal";
  backend?: FxBackendChoice;
  nativeAddon?: string | URL | false | object;
  wasm?: FxNodeWasmSource;
}

/** What `getBackendInfo()` resolves to. */
export interface FxBackendInfo {
  surface: "agent" | "terminal";
  backend: "native" | "wasm-jspi" | "unavailable";
  attempts: FxBackendAttempt[];
}

// ---------------------------------------------------------------------------
// Interactive terminal

/** The terminal a terminal runtime draws on. `xtermAdapter()` builds one from xterm.js. */
export interface FxTerminalAdapter {
  write(bytes: Uint8Array): void;
  /** Subscribes to user input; returns the unsubscribe function. */
  onData(callback: (data: string | Uint8Array) => void): (() => void) | void;
  onKeyData?(callback: (data: string | Uint8Array) => void): (() => void) | void;
  onResize(callback: () => void): (() => void) | void;
  readonly cols: number;
  readonly rows: number;
  /** Resolves once written output has drained. */
  drain?(): unknown;
}

/** The result of one workspace command. */
export interface FxWorkspaceExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/** A browser workspace: completion-only `shell.run` and optional AGENTS.md reads. */
export interface FxWorkspace {
  info: { version: 1; root: string; cwd: string; home: string; gitAvailable: false; ephemeral: true };
  permission: "allow-sandboxed" | "prompt";
  exec(request: { command: string; cwd: string; signal: AbortSignal; timeoutMs: number; outputLimitBytes: number }): FxWorkspaceExecResult | Promise<FxWorkspaceExecResult>;
  /** Returns a string, UTF-8 bytes, or null when the file does not exist. */
  readFile?(request: { path: string; signal: AbortSignal }): string | FxBytes | null | undefined | Promise<string | FxBytes | null | undefined>;
}

/** A diagnostic a terminal runtime passes to `onEvent`. */
export interface FxTerminalEvent {
  type: string;
  timestamp: number;
  [key: string]: unknown;
}

/** Options for `createFxTerminal()`. */
export interface FxTerminalOptions {
  terminal: FxTerminalAdapter;
  env?: Readonly<Record<string, string>>;
  args?: readonly string[];
  /** Input that aborts host effects. Default Ctrl+C (`"\x03"`). */
  interruptKey?: string;
  fetch?: FxFetch;
  onEvent?: (event: FxTerminalEvent) => void;
  workspace?: FxWorkspace;
  /** Defaults to `navigator.clipboard`. */
  clipboard?: { writeText(text: string): unknown } | null;
  /** Opens a URL; return `false` when it was not opened. */
  openUrl?: (url: string) => unknown;
  sessionStore?: unknown;
  configStore?: unknown;
  oauthSessionStore?: unknown;
  promptHistoryStore?: unknown;
}

/** A running terminal harness. */
export interface FxTerminal {
  /** Resolves once the terminal is interactive. */
  readonly interactive: Promise<void>;
  /** Resolves with the exit code. */
  readonly exited: Promise<number>;
  write(data: string | Uint8Array): void;
  resize(): void;
  abort(): void;
}

/** The parts of a keyboard event `encodeXtermKeyEvent()` reads. */
export interface FxKeyEventLike {
  readonly type: string;
  readonly key: string;
  readonly altKey: boolean;
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly metaKey: boolean;
}

/** The parts of an xterm.js `Terminal` `xtermAdapter()` uses. */
export interface FxXtermLike {
  readonly cols: number;
  readonly rows: number;
  write(data: string): void;
  onData(callback: (data: string) => void): { dispose(): void };
  onResize(callback: (size: { cols: number; rows: number }) => void): { dispose(): void };
  attachCustomKeyEventHandler?(handler: (event: FxKeyEventLike) => boolean): void;
  hasSelection?(): boolean;
  readonly element?: unknown;
  readonly modes?: { readonly mouseTrackingMode?: string };
}

/** Connects an xterm.js terminal to `createFxTerminal()`. */
export declare function xtermAdapter(term: FxXtermLike): FxTerminalAdapter;

/** The terminal input for a browser keyboard shortcut the composer handles, or null. */
export declare function encodeXtermKeyEvent(event: FxKeyEventLike): string | null;

// ---------------------------------------------------------------------------
// Shared values

/** Whether this JavaScript runtime provides JavaScript Promise Integration (JSPI). */
export declare function supportsJspi(): boolean;

/** Sorted, unique language-model IDs from one bounded Gateway request. */
export declare function listModels(options: FxListModelsOptions): Promise<string[]>;

/** The version of the WebAssembly SDK API. */
export declare const fxSdkApiVersion: 2;
