// `libfx/mcp` (mcp.js): tools and instructions from a host-owned MCP client.
import type { FxAgentHostTool } from "./libfx.cjs";

/**
 * The parts of an MCP client the adapter calls, with the MCP TypeScript SDK
 * v1 signatures. Transport, authentication, elicitation, and cleanup stay
 * with the host.
 */
export interface McpClient {
  /** Resolves to the tools array or `{ tools, nextCursor? }`. */
  listTools(params?: { cursor: string }): unknown;
  /** Called with the tool's original name, the model's arguments, and the turn's `signal` in `options`. */
  callTool(params: { name: string; arguments?: unknown; _meta?: { "libfx/correlationId": string } }, resultSchema?: unknown, options?: { signal?: AbortSignal }): unknown;
  getServerVersion?(): { name?: string } | undefined;
  /** Required when `resources` is given. */
  readResource?(params: { uri: string }): unknown;
  /** Required when `prompts` is given. */
  getPrompt?(params: { name: string; arguments?: Record<string, string> }): unknown;
  close?(): unknown;
}

/** Options for `createMcpAdapter()`. */
export interface McpAdapterOptions {
  /** Local server identity for hook events. Defaults to the client's reported server name, or null. */
  serverName?: string;
  /** Send an opaque UUID as `_meta["libfx/correlationId"]`. Default false; doesn't request MCP progress notifications. */
  propagateCorrelation?: boolean;
  /** Prepended to each tool name: letters, digits, `_`, or `-`. */
  prefix?: string;
  /** Resource URIs whose text becomes instructions. */
  resources?: readonly string[];
  /** Prompts whose text becomes instructions: a name, or a `getPrompt()` request. */
  prompts?: readonly (string | { name: string; arguments?: Record<string, string> })[];
}

/** What `createMcpAdapter()` resolves to. Pass `tools` and `instructions` to the agent. */
export interface McpAdapter {
  /** Each tool has `idempotent: false`; set it to `true` on a tool known to be safe to run twice. */
  tools: FxAgentHostTool[];
  instructions: string;
  /** Closes the client once. */
  close(): Promise<void>;
}

/** Adapts a host-owned MCP client into agent tools and instructions. */
export declare function createMcpAdapter(client: McpClient, options?: McpAdapterOptions): Promise<McpAdapter>;
