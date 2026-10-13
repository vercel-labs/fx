// A single engine as a Node.js consumer uses it: the README's createFxEngine,
// prompt input, steering, follow-ups, checkpoints, persistence, and models.
import {
  createFxAgent,
  createFxEngine,
  createMemoryPersistence,
  FxFencedError,
  getBackendInfo,
  libfxApiVersion,
  listModels,
  fxSdkApiVersion,
  supportsJspi,
  type FxProviderCredentials,
  type FxEngine,
  type FxEngineEvent,
  type FxEngineTurn,
  type FxEngineTurnResult,
  type FxHostTool,
  type FxToolResult,
  type JournalRecord,
  type Persistence,
  type PersistenceLoadResult,
} from "libfx";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const process: { env: Record<string, string | undefined> };
declare const apiKey: string;
declare const model: string;
declare const file: File;
declare const pngBytes: Uint8Array;
declare const base64Png: string;
declare const sharp: (bytes: Uint8Array) => { resize(options: object): { png(): { toBuffer(): Promise<Uint8Array> } } };
declare const imageStore: { prepareCopy(sourceRef: string, options: { maxSide: number; signal: AbortSignal }): Promise<{ base64: string; mimeType: string }> };

// README "A single engine" and "Prompt input".
export async function engine(): Promise<FxEngine> {
  const agent = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY ?? "", model });
  assertType<Equal<typeof agent.sessionId, string>>();

  const turn = agent.prompt("Update the index.");
  for await (const _ of turn) {}
  const result = await turn.result;
  assertType<Equal<typeof result, FxEngineTurnResult>>();
  assertType<Equal<typeof result.stopReason, "end_turn" | "max_output_tokens" | "max_model_turns" | "refused" | "cancelled">>();

  agent.prompt([
    { type: "text", text: "What does this screenshot show?" },
    { type: "image", data: file, sourceRef: "uploads:screenshot-1" }, // File or Blob, with file.type
    { type: "image", data: pngBytes, mimeType: "image/png" },
    { type: "image", data: new ArrayBuffer(8), mimeType: "image/png" },
    { type: "image", data: new DataView(new ArrayBuffer(8)), mimeType: "image/png" },
    { type: "image", data: base64Png, mimeType: "image/png" },
  ]);
  agent.prompt([{ type: "image", mimeType: "image/png", sourceRef: "uploads:screenshot-1" }]);
  agent.prompt([{ type: "resource", resource: { uri: "repo://instructions", text: "Use tabs." } }, { type: "resource", uri: "repo://notes" }]);
  agent.prompt("Hello", { signal: AbortSignal.timeout(1000) });

  // @ts-expect-error raw bytes need an explicit mimeType
  agent.prompt([{ type: "image", data: pngBytes }]);
  // @ts-expect-error a reference-only image needs a mimeType
  agent.prompt([{ type: "image", sourceRef: "uploads:screenshot-1" }]);
  // @ts-expect-error unsupported prompt block type
  agent.prompt([{ type: "audio", data: base64Png }]);

  return agent;
}

// README "resizeImage" and the host image tool.
export async function images(): Promise<void> {
  await createFxEngine({
    apiKey,
    model,
    async resizeImage({ bytes }) {
      const png = await sharp(bytes).resize({ width: 1568, withoutEnlargement: true }).png().toBuffer();
      return { bytes: png, mimeType: "image/png" };
    },
  });
  await createFxEngine({ apiKey, resizeImage: async ({ mimeType }) => ({ bytes: new ArrayBuffer(8), mimeType }) });

  const prepareImage: FxHostTool<{ sourceRef: string; maxSide: number }> = {
    name: "prepare_image",
    description: "Return a new smaller copy of a host-owned image. Use the request limit for maxSide.",
    inputSchema: {
      type: "object",
      properties: { sourceRef: { type: "string" }, maxSide: { type: "integer" } },
      required: ["sourceRef", "maxSide"],
    },
    async execute({ sourceRef, maxSide }, { signal }) {
      const copy = await imageStore.prepareCopy(sourceRef, { maxSide, signal });
      const result: FxToolResult = {
        type: "libfx.tool-result",
        text: "Prepared a new copy; original unchanged.",
        images: [
          { type: "image", data: copy.base64, mimeType: copy.mimeType, sourceRef },
          { type: "image", mimeType: "image/png", sourceRef: "uploads:screenshot-1" },
        ],
      };
      return result;
    },
  };
  await createFxEngine({ apiKey, model, tools: [prepareImage] });

  // @ts-expect-error a tool image needs base64 data or a sourceRef
  const bad: FxToolResult = { type: "libfx.tool-result", text: "", images: [{ type: "image", mimeType: "image/png" }] };
  void bad;
}

// README steering and follow-ups.
export async function steering(agent: FxEngine): Promise<void> {
  const turn: FxEngineTurn = agent.prompt("Build the feature.");
  for await (const event of turn) {
    if (event.type === "tool_end" && event.name === "read_file") {
      await turn.steer("Keep the public API backward compatible.");
    }
  }
  const steer = turn.steer([{ type: "text", text: "Prefer small diffs." }], "steer_1");
  assertType<Equal<typeof steer.id, string>>();
  const { id } = await steer;
  const withdrawn = await turn.withdraw(id);
  assertType<Equal<typeof withdrawn, "withdrawn" | "already_placed">>();
  // @ts-expect-error steering accepts only text blocks
  turn.steer([{ type: "image", data: "aGk=", mimeType: "image/png" }]);
  turn.cancel();

  const followUp = agent.followUp("Then run the tests.");
  assertType<Equal<typeof followUp.id, string>>();
  const accepted = await followUp.accepted;
  assertType<Equal<typeof accepted, { id: string }>>();
  const next = await followUp;
  console.log(next.id, await next.result);

  const checkpoint = await agent.checkpoint();
  const restored = await createFxEngine({ apiKey, model, checkpoint });
  await restored.close();
}

// README "Persistence".
class SessionStore implements Persistence {
  readonly #records: Array<JournalRecord & { key: string }> = [];

  async load(): Promise<PersistenceLoadResult> {
    return { journal: this.#records.map(({ cursor, data }) => ({ cursor, data })) };
  }

  async append({ expected, idempotencyKey, data }: { expected: string | null; idempotencyKey: string; data: Uint8Array }): Promise<{ cursor: string }> {
    const stored = this.#records.find((record) => record.key === idempotencyKey);
    if (stored) return { cursor: stored.cursor };
    const head = this.#records.at(-1)?.cursor ?? null;
    if (expected !== head) throw new FxFencedError(`another agent appended to this session: expected ${expected}, head ${head}`);
    const cursor = String(this.#records.length + 1);
    this.#records.push({ cursor, data: data.slice(), key: idempotencyKey });
    return { cursor };
  }
}

export async function persistence(): Promise<void> {
  const memoryStore = createMemoryPersistence();
  const agent = await createFxEngine({ apiKey, model, persistence: memoryStore, sessionId: "support-42", checkpointAfterBytes: 0 });
  console.log(memoryStore.records.at(0)?.cursor, memoryStore.checkpoint?.through);

  for (let turn = agent.resume(); turn; turn = agent.resume()) {
    for await (const event of turn) console.log(event);
    await turn.result;
  }

  const resumed = agent.resume({ onAmbiguous: ({ executionId, name, input }) => (name === "get_order" ? "rerun" : (console.log(executionId, input), undefined)) });
  resumed?.cancel({ reason: "handoff" });
  agent.prompt("Refund order 42.", { turnId: "turn_refund_42", onAmbiguous: () => "rerun" });

  await createFxEngine({ apiKey, persistence: new SessionStore() });

  const checkpoint = await agent.checkpoint();
  // @ts-expect-error persistence cannot be combined with checkpoint
  await createFxEngine({ apiKey, persistence: memoryStore, checkpoint });
  // @ts-expect-error checkpointAfterBytes needs persistence
  await createFxEngine({ apiKey, checkpointAfterBytes: 0 });
  // @ts-expect-error apiKey is required
  await createFxEngine({ model });
  // @ts-expect-error onAmbiguous answers "rerun" or nothing
  agent.resume({ onAmbiguous: () => "skip" });
}

// README "Models" and "Backends".
export async function models(): Promise<void> {
  const ids = await listModels({ apiKey: process.env.AI_GATEWAY_API_KEY ?? "" });
  assertType<Equal<typeof ids, string[]>>();
  await listModels({ apiKey, fetch: (input, init) => fetch(input, init) });
  // @ts-expect-error listModels() needs an apiKey
  await listModels({});

  createFxAgent({ apiKey, model, modelCatalog: [{ id: model }] });

  const info = await getBackendInfo({ surface: "agent", backend: "auto" });
  assertType<Equal<typeof info.backend, "native" | "wasm-jspi" | "unavailable">>();
  for (const attempt of info.attempts) {
    if (!attempt.available) console.log(attempt.backend, attempt.reason.code, attempt.reason.causeCode);
  }
  await getBackendInfo({ surface: "terminal", nativeAddon: false, wasm: Promise.resolve("https://cdn.example.com/fx-term.wasm") });
  await getBackendInfo();
  // @ts-expect-error getBackendInfo() accepts only surface, backend, nativeAddon, and wasm
  await getBackendInfo({ apiKey });

  await createFxEngine({ apiKey, backend: "wasm", wasm: fetch("https://cdn.example.com/fx-core.wasm") });
  await createFxEngine({ apiKey, backend: "native", nativeAddon: "./libfx.darwin-arm64.node" });

  assertType<Equal<typeof libfxApiVersion, 3>>();
  assertType<Equal<typeof fxSdkApiVersion, 2>>();
  assertType<Equal<ReturnType<typeof supportsJspi>, boolean>>();
}

// An engine's `onEvent` receives runtime diagnostics only.
export async function events(): Promise<void> {
  const seen: FxEngineEvent[] = [];
  await createFxEngine({
    apiKey,
    onEvent(event) {
      seen.push(event);
      if (event.type === "transport.retry") console.log(event.nextAttempt);
      if (event.type === "checkpoint.save") console.log(event.through, event.bytes);
      if (event.type === "journal.error") console.log(event.error);
      // @ts-expect-error session events come from createFxAgent(), not an engine
      if (event.type === "session.error") console.log(event);
    },
  });
}

// A Codex engine on the host's ChatGPT credentials.
declare const tokenStore: {
  load(provider: "codex", sessionId?: string): Promise<FxProviderCredentials>;
  save(provider: "codex", credentials: FxProviderCredentials): Promise<void>;
};
declare const accountLocks: { run<T>(key: string, fn: () => Promise<T>): Promise<T> };
export async function codexEngine(): Promise<FxEngine> {
  const engine = await createFxEngine({
    provider: "codex",
    model: "gpt-6.1-sol",
    credentials: ({ provider, sessionId }) => tokenStore.load(provider, sessionId),
    onCredentials: (credentials, { provider }) => tokenStore.save(provider, credentials),
    refreshLock: ({ provider, sessionId }, refresh) => accountLocks.run(`${provider}:${sessionId ?? "catalog"}`, refresh),
  });
  // @ts-expect-error a Codex engine needs credentials()
  await createFxEngine({ provider: "codex", model });
  // @ts-expect-error credentials() needs provider "codex"
  await createFxEngine({ apiKey, model, credentials: () => tokenStore.load("codex") });
  // @ts-expect-error onCredentials needs provider "codex"
  await createFxEngine({ apiKey, model, onCredentials: () => {} });
  // @ts-expect-error refreshLock needs provider "codex"
  await createFxEngine({ apiKey, model, refreshLock: async (_info, refresh) => refresh() });
  // @ts-expect-error a Gateway engine needs apiKey
  await createFxEngine({ provider: "gateway", model });
  // @ts-expect-error a provider named by string is Gateway, Codex or Grok
  await createFxEngine({ provider: "custom", apiKey, model });
  return engine;
}

// A custom provider: a local server needs no key; a hosted one gets the host's.
declare const providerKeys: { load(provider: string, sessionId?: string): Promise<string> };
export async function customEngine(): Promise<FxEngine> {
  const local = await createFxEngine({
    provider: { name: "local", baseUrl: "http://localhost:11434/v1", models: { "qwen3:8b": { contextWindow: 32768, supportsToolUse: true } } },
    model: "qwen3:8b",
  });
  await local.close();
  const router = { name: "router", baseUrl: "https://openrouter.ai/api/v1" };
  const engine = await createFxEngine({
    provider: router,
    model: "qwen/qwen3-coder",
    credentials: async ({ provider, sessionId }) => ({ apiKey: await providerKeys.load(provider, sessionId) }),
  });
  // @ts-expect-error a custom provider's credentials are an API key
  await createFxEngine({ provider: router, model, credentials: () => tokenStore.load("codex") });
  // @ts-expect-error a custom provider's key is never refreshed
  await createFxEngine({ provider: router, model, onCredentials: () => {} });
  // @ts-expect-error a custom provider's key is never refreshed, so it takes no lock
  await createFxEngine({ provider: router, model, refreshLock: async (_info, refresh) => refresh() });
  // @ts-expect-error a custom provider needs a base URL
  await createFxEngine({ provider: { name: "router" }, model });
  // @ts-expect-error model details use libfx's option names
  await createFxEngine({ provider: { ...router, models: { m: { context_window: 1 } } }, model });
  return engine;
}

// A Grok engine on the host's Grok credentials; one store serves both plans.
declare const planTokens: { load(provider: "codex" | "grok", sessionId?: string): Promise<FxProviderCredentials> };
export async function grokEngine(): Promise<FxEngine> {
  const engine = await createFxEngine({
    provider: "grok",
    model: "grok-4.5",
    credentials: ({ provider, sessionId }) => planTokens.load(provider, sessionId),
  });
  // @ts-expect-error a Grok request names provider "grok"
  await createFxEngine({ provider: "grok", model, credentials: ({ provider }) => tokenStore.load(provider) });
  return engine;
}
