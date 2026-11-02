// The durable agent as a Node.js consumer uses it: the README's examples,
// sessions, turns, durabilities, tools, and errors.
import {
  createFxAgent,
  createMemoryPersistence,
  FxFencedError,
  FxJournalVersionError,
  memory,
  wakeHandler,
  type Durability,
  type FxAgent,
  type FxAgentEvent,
  type FxAgentTools,
  type FxResumeTurn,
  type FxSession,
  type FxStopReason,
  type FxStreamLine,
  type FxToolContext,
  type FxTools,
  type FxTurn,
  type FxTurnResult,
  type FxUsage,
  type JsonValue,
} from "libfx";
import { local } from "libfx/durable-local";
import { vercel } from "libfx/durable-vercel";
import { world, type World, type WorldOptions } from "libfx/durable-world";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const process: { stdout: { write(text: string): void }; env: Record<string, string | undefined> };
declare const apiKey: string;

// README "Agent".
export async function readmeAgent(): Promise<void> {
  const agent = createFxAgent({
    model: "google/gemini-2.5-flash-lite",
    instructions: "Answer in one paragraph.",
  });

  const turn = agent.session().prompt("Explain this project.");

  for await (const event of turn) {
    if (event.type === "text_delta") process.stdout.write(event.delta);
  }

  const result = await turn.result;
  console.log(result.messageId, result.stopReason, result.usage);
  await agent.close();
}

// README "Sessions" and "Turns".
export async function sessionsAndTurns(agent: FxAgent): Promise<void> {
  const turn = agent.session().prompt("Plan the migration.");
  const { sessionId } = await turn.accepted;
  assertType<Equal<typeof sessionId, string>>();

  const followUp = agent.session(sessionId).prompt("Start with the schema.");
  assertType<Equal<typeof followUp, FxTurn>>();
  assertType<Equal<typeof followUp.messageId, string>>();

  const id = await agent.newSessionId();
  assertType<Equal<typeof id, string>>();
  const known: FxSession = agent.session(id, { context: { userId: "user_1", roles: ["admin"], limit: 3 } });
  agent.session(undefined, { context: null });
  agent.session(id, { model: "openai/gpt-5", instructions: ["Design rules.", "House style."] });
  agent.session(id, { model: { id: "anthropic/claude-haiku-4.5", effort: "low", fast: true }, context: { userId: "user_1" } });
  // @ts-expect-error a session's model takes no top-level effort
  agent.session(id, { model: "openai/gpt-5", effort: "low" });
  // @ts-expect-error instructions are text
  agent.session(id, { instructions: 5 });
  assertType<Equal<typeof known.id, string | null>>();

  // @ts-expect-error null is not a session id: only a missing id starts a new session
  agent.session(null);
  // @ts-expect-error session context must be JSON
  agent.session(id, { context: () => 1 });

  const controller = new AbortController();
  const retried = known.prompt("Refund order 42.", { messageId: "msg_refund_42", signal: controller.signal });
  const result: FxTurnResult = await retried.result;
  assertType<Equal<typeof result.stopReason, FxStopReason | "error" | "unknown">>();
  assertType<Equal<typeof result.usage, FxUsage | undefined>>();
  assertType<Equal<typeof result.repeated, true | undefined>>();
  if (result.stopReason === "error") console.log(result.error?.name, result.error?.message, result.error?.code);
  console.log(result.epoch);

  for await (const event of retried) {
    if (event.type === "tool_start") console.log(event.id, event.name, event.inputTruncated ? event.inputPreview : event.input);
    if (event.type === "tool_end") console.log(event.content, event.isError);
    if (event.type === "user_message") console.log(event.text, event.id);
    console.log(event.epoch);
  }

  const body: ReadableStream<Uint8Array> = retried.readable;
  void new Response(body);

  // @ts-expect-error dropping or cancelling a view cancels nothing; call session.cancel()
  retried.cancel();

  known.prompt([
    { type: "text", text: "What does this screenshot show?" },
    { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
    { type: "image", mimeType: "image/png", sourceRef: "uploads:screenshot-1" },
    { type: "resource", resource: { uri: "repo://notes", text: "Notes" } },
  ]);
  // @ts-expect-error a durable prompt carries image data as a base64 string
  known.prompt([{ type: "image", data: new Uint8Array(4), mimeType: "image/png" }]);
  // @ts-expect-error a durable prompt has no turnId; use messageId
  known.prompt("again", { turnId: "turn_1" });

  const stream = known.stream(17);
  assertType<Equal<typeof stream, ReadableStream<Uint8Array>>>();
  known.stream();

  await known.steer("Keep the public API backward compatible.");
  const steered = await known.steer("Prefer small diffs.", { messageId: "m12" });
  assertType<Equal<typeof steered.messageId, string>>();
  await known.steer([
    { type: "text", text: "Match this screenshot." },
    { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
  ]);
  // @ts-expect-error a durable steer carries image data as a base64 string
  known.steer([{ type: "image", data: new Uint8Array(4), mimeType: "image/png" }]);
  await known.cancel();
  const checkpoint = await known.checkpoint();
  assertType<Equal<typeof checkpoint, Uint8Array>>();
  createFxAgent({ checkpoint, durability: memory() });

  const resumed: FxResumeTurn = known.resume();
  assertType<Equal<typeof resumed.messageId, string | null>>();
  const outcome = await resumed.result;
  if (outcome.stopReason === "idle") {
    // @ts-expect-error an idle resume has no turn and so no messageId
    console.log(outcome.messageId);
  } else {
    assertType<Equal<typeof outcome.messageId, string>>();
  }

  assertType<Equal<typeof agent.sessionId, string | null>>();
  const own = agent.prompt("Hello");
  assertType<Equal<typeof own, FxTurn>>();
  const ownCheckpoint: Uint8Array = await agent.checkpoint();
  void ownCheckpoint;
}

// Stream lines a browser parses from `session.stream()` or `turn.readable`.
export function readLine(text: string): string | undefined {
  const line = JSON.parse(text) as FxStreamLine;
  switch (line.type) {
    case "turn_start":
    case "turn_resume":
      return line.sessionId;
    case "turn_end":
      return `${line.messageId} ${line.stopReason} ${line.cursor ?? "-"} ${line.epoch ?? "-"}`;
    case "idle":
      return line.requestId;
    case "text_delta":
      return line.delta;
    default:
      return line.messageId;
  }
}

// README "Durability".
export async function durabilities(): Promise<void> {
  createFxAgent({ durability: local({ dir: ".fx/sessions" }) });
  createFxAgent({ durability: memory() }); // nothing survives the process
  createFxAgent({ durability: memory({ maxDurationMs: 60_000, reserveMs: 5_000 }) });
  createFxAgent({ durability: local({ maxDurationMs: 300_000, reserveMs: 30_000 }) });
  createFxAgent({ durability: vercel({ reserveMs: 10_000 }) });
  createFxAgent({ durability: vercel({ reserveMs: 10_000, leaseMs: 5_000 }) });
  createFxAgent({ durability: vercel() });

  // @ts-expect-error memory() has no dir
  memory({ dir: ".fx/sessions" });
  // @ts-expect-error local() takes no World options
  local({ queueDurable: true });
  // @ts-expect-error vercel() takes only reserveMs and leaseMs
  vercel({ maxDurationMs: 60_000 });
  // @ts-expect-error durability must come from memory(), local(), vercel(), or world()
  createFxAgent({ durability: { name: "memory" } });

  const d: Durability = local();
  assertType<Equal<typeof d, ReturnType<typeof vercel>>>();
}

// README "Durability": a World the app creates, here a fake with the parts libfx uses.
declare function createWorld(options: { namespace: string; jobPrefix: string }): World & { start(): Promise<void> };

export async function worlds(): Promise<void> {
  const sessions = createWorld({ namespace: "libfx", jobPrefix: "libfx_" });
  await sessions.start();
  const agent = createFxAgent({ durability: world(sessions, { queueDurable: true }) });
  await agent.close();

  const fake: World = {
    specVersion: 3,
    events: {
      async create() { return { event: { eventId: "evnt_00000000000000000000000001" } }; },
      async list() { return { data: [], hasMore: false, cursor: null }; },
    },
    streams: {
      async write() {},
      async writeMulti() {},
      async get() { return new ReadableStream<Uint8Array>(); },
      async getChunks() { return { data: [], cursor: null, hasMore: false }; },
      async getInfo() { return { tailIndex: -1 }; },
    },
    async queue() { return { messageId: null }; },
    createQueueHandler() { return async () => new Response(null, { status: 204 }); },
    registerHandler() {},
    async getRuntimeDeadline() { return undefined; },
    createRunId: () => "01HZY0000000000000000000000",
  };
  world(fake);
  world(() => fake);
  world(async () => fake, { name: "postgres", pollMs: 500, maxDurationMs: 800_000, reserveMs: 30_000, leaseMs: 10_000 });
  world(fake, { name: "queues", queueLeases: true, queueDurable: true });
  world(fake, { queueLeases: true, runInRequest: false });
  world(fake, { queueLeases: true, waitUntil: (work) => void work });
  world(fake, {
    livenessKnown: true,
    holderInfo: () => ({ pid: 42, host: "worker-1" }),
    alive: (lease) => (lease.host === "worker-1" ? lease.pid === 42 : null),
    gatewayKey: async () => process.env.AI_GATEWAY_API_KEY ?? "",
  });
  const options: WorldOptions = { livenessKnown: false, queueDurable: false };
  world(fake, options);

  // @ts-expect-error livenessKnown needs alive()
  world(fake, { livenessKnown: true });
  // @ts-expect-error a World needs events, streams, a queue, and createQueueHandler()
  world({});
  // @ts-expect-error alive() answers true, false, or null
  world(fake, { alive: () => "yes" });
  // @ts-expect-error unknown world() option
  world(fake, { recoverActiveRuns: false });
}

// README "Tools with effects" and "JavaScript tools and instructions".
declare const database: { get(key: string, options: { signal: AbortSignal }): Promise<string> };
declare const payments: { refund(orderId: string, options: { idempotencyKey: string }): Promise<{ ok: boolean }> };

export function tools(): FxAgent {
  const inputSchema = { type: "object", properties: { orderId: { type: "string" } }, required: ["orderId"] };
  const effects = [
    { name: "get_order", description: "Look up an order.", idempotent: true, inputSchema, async execute(input: { orderId: string }, { executionId }: FxToolContext) { return { input, executionId }; } },
    { name: "refund_order", description: "Refund an order.", idempotent: true, writes: true, inputSchema, async execute(input: { orderId: string }, { executionId }: FxToolContext) { return payments.refund(input.orderId, { idempotencyKey: executionId }); } },
  ] satisfies FxAgentTools;
  // An agent's tools are an engine's tools too.
  const _engineTools: FxTools = effects;

  createFxAgent({
    apiKey,
    model: "anthropic/claude-haiku-4.5",
    instructions: ["Keep answers concise.", "Cite order ids."],
    tools: [
      ...effects,
      {
        name: "lookup",
        description: "Look up a value.",
        idempotent: true,
        inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
        async execute(input, context) {
          assertType<Equal<typeof context, FxToolContext>>();
          assertType<Equal<typeof context.context, JsonValue | undefined>>();
          assertType<Equal<typeof context.executionId, string>>();
          assertType<Equal<typeof context.sessionId, string>>();
          return database.get(input.key, { signal: context.signal });
        },
      },
      { name: "web_search", providerExecuted: true },
    ],
  });

  createFxAgent({
    tools: {
      lookup: { description: "Look up a value.", idempotent: true, inputSchema: { type: "object" }, execute: () => "value" },
      save: { name: "save", description: "Save.", idempotent: false, inputSchema: { type: "object" }, execute: () => ({ type: "libfx.tool-result", text: "Saved.", images: [] }) },
      web_search: { providerExecuted: true },
    },
  });

  // @ts-expect-error a tool needs a name
  createFxAgent({ tools: [{ description: "Look up a value.", idempotent: true, inputSchema: { type: "object" }, execute: () => "value" }] });
  // @ts-expect-error a host tool needs a description
  createFxAgent({ tools: [{ name: "lookup", idempotent: true, inputSchema: { type: "object" }, execute: () => "value" }] });
  // @ts-expect-error a host tool must say whether it is idempotent
  createFxAgent({ tools: [{ name: "lookup", description: "Look up a value.", inputSchema: { type: "object" }, execute: () => "value" }] });
  // @ts-expect-error a keyed host tool must say so too
  createFxAgent({ tools: { lookup: { description: "Look up a value.", inputSchema: { type: "object" }, execute: () => "value" } } });
  // @ts-expect-error a provider-executed tool must not define execute()
  createFxAgent({ tools: [{ name: "web_search", providerExecuted: true, execute: () => "value" }] });
  // @ts-expect-error a keyed descriptor's name must be a string
  createFxAgent({ tools: { lookup: { name: 1, description: "Look up a value.", idempotent: true, inputSchema: {}, execute: () => "value" } } });

  return createFxAgent({ apiKey, tools: effects });
}

// README "Model options" and "Backends".
export function options(): void {
  createFxAgent({ model: { id: "anthropic/claude-opus-5.5-fast", effort: "low", fast: true } });
  createFxAgent({ model: { id: "openai/astra", ultrafast: true } });
  createFxAgent({ model: "openai/gpt-5", effort: "high", fast: false });
  createFxAgent();
  createFxAgent({ apiKey: process.env.AI_GATEWAY_API_KEY, model: process.env.FX_MODEL, durability: process.env.VERCEL ? vercel() : undefined });
  createFxAgent({ apiKey, backend: "auto" }); // native, then Wasm fallback
  createFxAgent({ apiKey, backend: "native" }); // require N-API
  createFxAgent({ apiKey, backend: "wasm" }); // require Wasm + JSPI
  createFxAgent({ apiKey, nativeAddon: false, wasm: new URL("file:///srv/fx-core.wasm") });
  createFxAgent({ apiKey, modelCatalog: [{ id: "anthropic/claude-haiku-4.5", type: "language" }] });
  createFxAgent({ apiKey, modelCatalog: { data: [] }, gatewayChatUrl: "http://127.0.0.1:8787/chat", fetch: (input, init) => fetch(input, init) });

  // @ts-expect-error model options cannot be mixed with top-level effort
  createFxAgent({ model: { id: "anthropic/claude-opus-5.5-fast" }, effort: "low" });
  // @ts-expect-error unsupported model option
  createFxAgent({ model: { id: "anthropic/claude-opus-5.5-fast", temperature: 0 } });
  // @ts-expect-error env is reserved for createFxTerminal()
  createFxAgent({ env: { AI_GATEWAY_API_KEY: apiKey } });
  // @ts-expect-error createFxAgent() keeps sessions itself and takes no persistence
  createFxAgent({ persistence: createMemoryPersistence() });
  // @ts-expect-error createFxAgent() names sessions itself
  createFxAgent({ sessionId: "support-42" });
  // @ts-expect-error unknown backend
  createFxAgent({ backend: "gpu" });
}

// `onEvent` receives the engines' diagnostics and the sessions'.
export function events(): void {
  const seen: FxAgentEvent[] = [];
  createFxAgent({
    onEvent(event) {
      seen.push(event);
      assertType<Equal<typeof event.timestamp, number>>();
      if (event.type === "session.error") console.log(event.sessionId, event.error.message);
      if (event.type === "session.deadline" || event.type === "session.fenced") assertType<Equal<typeof event.epoch, number>>();
      if (event.type === "session.deadline") assertType<Equal<typeof event.cutoffs, number>>();
      if (event.type === "session.forwarded") assertType<Equal<typeof event.agent, string>>();
      if (event.type === "checkpoint.mismatch") console.log(event.changed.includes("model"), event.current.toolSchemaHash);
      if (event.type === "transport.activity") console.log(event.attempt, event.chunkBytes, event.totalBytes);
      if (event.type === "transport.response") console.log(event.status, event.requestId);
    },
  });
}

// The two errors are classes: `instanceof` narrows them.
export function errors(error: unknown): string {
  if (error instanceof FxFencedError) {
    assertType<Equal<typeof error.code, "FX_FENCED">>();
    return error.message;
  }
  if (error instanceof FxJournalVersionError) {
    assertType<Equal<typeof error.code, "FX_JOURNAL_VERSION">>();
    return error.name;
  }
  const fenced: Error = new FxFencedError("expected 3, head 4");
  return fenced.message;
}

// README "Next.js and Vercel".
const agent = createFxAgent({ model: "anthropic/claude-haiku-4.5", tools: [] });

export async function POST(request: Request): Promise<Response> {
  const sessionId = new URL(request.url).searchParams.get("sessionId") ?? undefined;
  const turn = agent.session(sessionId).prompt(await request.text());
  return new Response(turn.readable);
}

export async function GET(request: Request): Promise<Response> {
  const params = new URL(request.url).searchParams;
  const sessionId = params.get("sessionId");
  // @ts-expect-error searchParams.get() can return null, which session() rejects
  agent.session(params.get("sessionId"));
  if (sessionId === null) return new Response("sessionId is required", { status: 400 });
  const stream = agent.session(sessionId).stream(Number(params.get("cursor") ?? 0));
  return new Response(stream);
}

export const wake: (request: Request) => Promise<Response> = agent.wakeHandler();

// Several agents: each named, one route for all of them.
export const support: FxAgent = createFxAgent({ name: "support", instructions: "Answer billing questions." });
assertType<Equal<typeof support.name, string>>();
export const wakeAll: (request: Request) => Promise<Response> = wakeHandler();
// @ts-expect-error a name is text
createFxAgent({ name: 7 });

// A durable Codex agent: each process asks the host for the session's credentials.
export const codexAgent: FxAgent = createFxAgent({
  provider: "codex",
  model: "gpt-6.1-sol",
  credentials: async ({ sessionId }) => ({ accessToken: sessionId ?? "token", refreshToken: "refresh" }),
});
