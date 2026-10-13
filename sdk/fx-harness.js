// fx as a harness of the durable core in durable.js: `createFxAgent` is that
// core running fx engines. Everything the core needs to know about fx is
// here; the core itself knows only the harness contract.
import { coreAnswered, engineInternals, journalMarksWanted, normalizeInstructions, normalizeModelChoice } from "./fx-sdk.js";
import { createCredentialMemory, credentialMemory } from "./subscription.js";

const encoder = new TextEncoder();
// Every worker reads each record since the session's last checkpoint, so a
// durable session checkpoints far sooner than the engine's default.
const durableCheckpointAfterBytes = 64 * 1024;

/**
 * The fx harness for `createDurableAgentFactory`. `createEngine(options)`
 * returns a `createFxEngine` session, and `defaultApiKey(durability)` the
 * credential when the caller passes none.
 */
export function fxHarness({ createEngine, defaultApiKey = async () => undefined }) {
  return (options) => {
    const { checkpoint, ...engineOptions } = options;
    // `env` is refused here as well as by the engine, so the error names
    // createFxAgent() when the agent is created, not when a session opens.
    for (const name of ["env", "persistence", "checkpointAfterBytes", "sessionId", "inputsDurable", "toolContext"]) {
      if (Object.hasOwn(engineOptions, name)) throw new TypeError(`createFxAgent() does not accept ${name}`);
    }
    const idempotent = idempotentTools(engineOptions.tools);
    // One for all of this agent's sessions, so they refresh an account once.
    const credentials = createCredentialMemory();
    return {
      ...(checkpoint === undefined ? {} : { seed: snapshotOf(checkpointBytesOf(checkpoint)) }),
      settings: sessionSettings,
      async open({ sessionId, store, context, settings, durability, ready }) {
        const apiKey = engineOptions.apiKey ?? await defaultApiKey(durability);
        const engine = await createEngine({
          ...withSettings(engineOptions, settings),
          ...(apiKey === undefined ? {} : { apiKey }),
          ...(ready === undefined || engineOptions.tools === undefined ? {} : { tools: claimedTools(engineOptions.tools, ready) }),
          sessionId,
          [credentialMemory]: credentials,
          // The core folds the session from the marks on each record.
          persistence: { ...store, [journalMarksWanted]: true },
          inputsDurable: true,
          // A turn's end saves a checkpoint once the records since the last
          // one reach this many bytes, so a short turn writes none and a
          // worker reads back little; where a turn yields, the core saves
          // one itself before it lets the session go.
          checkpointAfterBytes: durableCheckpointAfterBytes,
          ...(context === undefined || context === null ? {} : { toolContext: context }),
        });
        return fxSession(engine, idempotent);
      },
    };
  };
}

// What `agent.session(id, { model, instructions })` sets for the turns it
// starts, checked as the engine checks it and copied, since the core stores
// it with each prompt; undefined when it sets neither.
function sessionSettings({ model, instructions } = {}) {
  if (model !== undefined) {
    if (typeof model !== "string" && (model === null || typeof model !== "object" || Array.isArray(model))) {
      throw new TypeError("session model must be a model id or a model object");
    }
    normalizeModelChoice({ model });
  }
  if (instructions !== undefined) normalizeInstructions(instructions);
  if (model === undefined && instructions === undefined) return undefined;
  return JSON.parse(JSON.stringify({ model, instructions }));
}

// The agent's engine options with a session's settings over them. A
// session's model replaces the agent's whole model choice, its effort and
// fast options included.
function withSettings(engineOptions, settings) {
  if (!settings) return engineOptions;
  const { model: _model, effort: _effort, fast: _fast, ultrafast: _ultrafast, ...rest } = engineOptions;
  return {
    ...(settings.model === undefined ? engineOptions : { ...rest, model: settings.model }),
    ...(settings.instructions === undefined ? {} : { instructions: settings.instructions }),
  };
}

// The engine reports a fenced write as the cause of the append that failed;
// the core knows a fence by its own `FX_FENCED` code.
const unwrapFence = (error) => (error?.cause?.code === "FX_FENCED" ? error.cause : error);

// How long a failed turn waits to learn whether its core exited.
const exitWaitMs = 1000;

// A failed turn's error as the core reads it: a fence; a turn the core
// ended with an error; or, when the core exited under it, a harness that
// stopped, which the next delivery replaces.
async function turnError(error, exited) {
  const unwrapped = unwrapFence(error);
  if (unwrapped?.code === "FX_FENCED" || unwrapped?.[coreAnswered]) return unwrapped;
  let timer;
  const gone = await Promise.race([
    exited.then(() => true, () => true),
    new Promise((resolve) => { timer = setTimeout(() => resolve(false), exitWaitMs); }),
  ]).finally(() => clearTimeout(timer));
  if (!gone) return unwrapped;
  return Object.assign(new Error(String(unwrapped?.message ?? unwrapped), { cause: unwrapped }), { code: "FX_HARNESS_STOPPED" });
}

function fxTurn(turn, exited) {
  const result = turn.result.catch(async (error) => { throw await turnError(error, exited); });
  void result.catch(() => {});
  return {
    result,
    steer: (text, id) => turn.steer(text, id),
    cancel: (options) => turn.cancel(options),
    async *[Symbol.asyncIterator]() {
      try {
        for await (const event of turn) yield event;
      } catch (error) {
        throw await turnError(error, exited);
      }
    },
  };
}

// A turn the engine would not start because of its input: it ends at once
// with an error and stores nothing.
function refusedTurn(error) {
  return {
    result: Promise.resolve({ stopReason: "error", usage: {}, error: { name: error?.name ?? "Error", message: String(error?.message ?? error) } }),
    steer: async () => {},
    cancel() {},
    async *[Symbol.asyncIterator]() {},
  };
}

function fxSession(engine, idempotent) {
  const internals = engine[engineInternals];
  return {
    prompt: (input, options) => {
      try {
        return fxTurn(engine.prompt(input, options), internals.exited);
      } catch (error) {
        // The engine refuses an input it cannot take with a TypeError or a
        // RangeError. Any other throw means it cannot run a turn at all.
        if (error instanceof TypeError || error instanceof RangeError) return refusedTurn(error);
        throw error;
      }
    },
    // A call left running reruns only when running it twice is safe, and
    // with `rerun: false` not even then. Any other call is never run again:
    // the model is told it may have partly run, and the turn goes on.
    resume: ({ rerun = true, ...options } = {}) => fxTurn(engine.resume({ ...options, onAmbiguous: (call) => (rerun && idempotent.has(call.name) ? "rerun" : undefined) }), internals.exited),
    get openTurn() {
      return internals.openTurn;
    },
    settled: () => internals.settled().catch((error) => { throw unwrapFence(error); }),
    saveCheckpoint: () => internals.checkpoint(),
    exportCheckpoint: () => engine.checkpoint(),
    close: () => engine.close(),
  };
}

function toolEntries(tools) {
  if (Array.isArray(tools)) return tools;
  if (tools && typeof tools === "object") return Object.entries(tools).map(([name, tool]) => ({ ...tool, name: tool?.name ?? name }));
  return [];
}

// The tools as a worker runs them: a turn can start before the worker's
// claim on the session lands, and no tool runs before it does.
function claimedTools(tools, ready) {
  const claimed = (tool) => (typeof tool?.execute !== "function" ? tool : {
    ...tool,
    async execute(...args) {
      if (!(await ready)) throw new Error("this worker's claim on the session failed");
      return tool.execute(...args);
    },
  });
  if (Array.isArray(tools)) return tools.map(claimed);
  if (tools && typeof tools === "object") return Object.fromEntries(Object.entries(tools).map(([name, tool]) => [name, claimed(tool)]));
  return tools;
}

// The tools whose cut-off calls run again. Every tool the host runs must say
// whether that is safe, so the choice is never a default: `idempotent: true`
// when running a call twice is harmless, `false` when it is not. A tool that
// is not an object is left for the engine to refuse.
function idempotentTools(tools) {
  const names = new Set();
  for (const [index, tool] of toolEntries(tools).entries()) {
    if (!tool || typeof tool !== "object" || tool.providerExecuted === true) continue;
    if (typeof tool.idempotent !== "boolean") {
      const name = typeof tool.name === "string" ? tool.name : index;
      throw new TypeError(`tool ${name} must set idempotent: true if running a call twice is safe, or idempotent: false if it is not`);
    }
    if (tool.idempotent && typeof tool.name === "string") names.add(tool.name);
  }
  return names;
}

function checkpointBytesOf(value) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError("checkpoint must be bytes");
}

// A kernel checkpoint as the snapshot a session's log starts from: `FXSN`,
// version 1, then the event it covers through, the turn after it, and no
// turn id. The seed counts as the session's first event, so the engine's
// own events start at seq 2.
function snapshotOf(checkpoint) {
  const bytes = new Uint8Array(4 + 1 + 8 + 8 + 1 + checkpoint.byteLength);
  bytes.set(encoder.encode("FXSN"), 0);
  bytes[4] = 1;
  const view = new DataView(bytes.buffer);
  view.setBigUint64(5, 1n, true);
  view.setBigUint64(13, 1n, true);
  bytes[21] = 0;
  bytes.set(checkpoint, 22);
  return bytes;
}
