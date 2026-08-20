#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-core.mjs");
  process.exit(2);
}

const trace = process.env.FX_WASM_TRACE === "1";
const checkpoint = (message) => { if (trace) console.error(`[core-smoke] ${message}`); };

const encoded = new TextEncoder();
const catalogModels = [
  { id: "sdk/catalog-alpha", type: "language", released: 2, tags: ["tool-use"] },
  { id: "sdk/catalog-beta", type: "language", released: 1, tags: ["reasoning"] },
];
let fetchCalls = 0;
const generationIds = [];
const responseGenerationIds = [
  "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
  "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
];
let requestedModel;
let requestedSessionId;
let requestedSessionAffinity;
const persistedConfig = new Map([
  ["model", "sdk/catalog-alpha"],
  ["mode", "code"],
]);
const configStore = {
  get(configId) { return persistedConfig.get(configId) ?? null; },
  set(configId, value) { persistedConfig.set(configId, value); },
};
const mockFetch = async (url, init) => {
  checkpoint("fetch opened");
  if (init.method === "GET" && String(url).endsWith("/v1/models")) {
    return Response.json({ object: "list", data: catalogModels });
  }
  fetchCalls++;
  if (init.method !== "POST") throw new Error(`unexpected method ${init.method}`);
  const requestBody = JSON.parse(new TextDecoder().decode(init.body));
  const headers = new Headers(init.headers);
  requestedModel = headers.get("ai-language-model-id");
  requestedSessionId = headers.get("x-session-id");
  requestedSessionAffinity = headers.get("x-session-affinity");
  if (!Array.isArray(requestBody.prompt) && !Array.isArray(requestBody.messages)) {
    throw new Error("gateway request did not contain prompt messages");
  }
  const generationId = responseGenerationIds[fetchCalls - 1];
  if (!generationId) throw new Error(`missing generation ID for response ${fetchCalls}`);
  generationIds.push(generationId);
  return new Response(new ReadableStream({
    async start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"hello"}\n'));
      await new Promise((resolve) => setTimeout(resolve, 10));
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":" world"}\n'));
      controller.enqueue(encoded.encode(`data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}},"providerMetadata":{"gateway":{"generationId":"${generationId}"}}}\n`));
      controller.enqueue(encoded.encode("data: [DONE]\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

checkpoint("creating agent");
const sessionRecords = new Map();
let sessionRevision = 1;
let failNextCommit = false;
let failNextRemove = false;
const sessionStore = {
  async load(id) {
    const record = sessionRecords.get(id);
    return record ? { bytes: record.bytes.slice(), revision: record.revision } : null;
  },
  commit(id, bytes, expectedRevision) {
    if (failNextCommit) {
      failNextCommit = false;
      throw new Error("injected session commit failure");
    }
    const current = sessionRecords.get(id);
    if (current?.revision !== expectedRevision) {
      const error = new Error("session revision conflict");
      error.code = "FX_SESSION_REVISION_CONFLICT";
      throw error;
    }
    const revision = String(sessionRevision++);
    sessionRecords.set(id, { bytes: bytes.slice(), revision, updatedAtMs: Date.now() });
    return { revision };
  },
  async list() {
    return [...sessionRecords.entries()].map(([id, record]) => ({ id, updatedAtMs: record.updatedAtMs }));
  },
  async remove(id) {
    if (failNextRemove) {
      failNextRemove = false;
      throw new Error("injected session remove failure");
    }
    sessionRecords.delete(id);
  },
};
const events = [];
let initializeTimeout;
const agent = await Promise.race([
  createFxAgent({ backend: "wasm", wasm: await readFile(wasmPath), fetch: mockFetch, env: { AI_GATEWAY_API_KEY: "sdk-test-key" }, configStore, sessionStore, onEvent(event) { events.push(event); }, traceWasi: trace }),
  new Promise((_, reject) => {
    initializeTimeout = setTimeout(() => reject(new Error("timed out waiting for fx-core initialize")), 5000);
  }),
]).finally(() => clearTimeout(initializeTimeout));

checkpoint("agent initialized");
const session = await agent.createSession();
checkpoint("session created");
if (!session.id) throw new Error("session/new did not return a session id");
if (!session.modes?.currentModeId) throw new Error("session/new did not return a mode snapshot");
const modeOption = session.configOptions?.find((option) => option.id === "mode");
if (modeOption?.options.find((option) => option.value === "code")?.permissionMode !== "auto") throw new Error("code mode did not advertise auto permission mode");
if (modeOption?.options.find((option) => option.value === "ask")?.permissionMode !== "ask") throw new Error("ask mode did not advertise ask permission mode");
const modelOption = session.configOptions?.find((option) => option.id === "model");
if (!modelOption) throw new Error("session/new did not return model options");
for (const model of catalogModels) {
  if (!modelOption.options.some((option) => option.value === model.id)) throw new Error(`model catalog omitted ${model.id}`);
}
if (modelOption.currentValue !== "sdk/catalog-alpha") throw new Error(`stored model was not restored through ACP: ${modelOption.currentValue}`);
if (session.modes.currentModeId !== "code") throw new Error(`stored mode was not restored through ACP: ${session.modes.currentModeId}`);
await session.setModel("sdk/browser-test-model");
if (session.configOptions.find((option) => option.id === "model")?.currentValue !== "sdk/browser-test-model") throw new Error("model option did not update");
if (persistedConfig.get("model") !== "sdk/browser-test-model") throw new Error("accepted model was not persisted");
failNextCommit = true;
let modelCommitRejected = false;
try { await session.setModel("sdk/rejected-model"); } catch { modelCommitRejected = true; }
if (!modelCommitRejected) throw new Error("host session commit failure was accepted");
if (!events.some((event) => event.type === "config.changed" && event.configId === "model" && event.value === "sdk/browser-test-model" && event.source === "sdk")) {
  throw new Error("accepted agent model change did not emit config.changed");
}
if (!events.some((event) => event.type === "config.changed" && event.configId === "mode" && event.value === "code" && event.source === "restore")) {
  throw new Error("restored agent mode did not emit config.changed with restore source");
}
await session.setMode("code");
if (session.modes.currentModeId !== "code") throw new Error("mode did not update to code");
await session.setMode("ask");
if (session.modes.currentModeId !== "ask") throw new Error("mode did not update to ask");

const turn = session.prompt([
  { type: "text", text: "say hello" },
  { type: "resource", uri: "https://example.test/context.txt", text: `browser SDK context ${"x".repeat(6000)}` },
]);
checkpoint("prompt sent");
const chunks = [];
for await (const update of turn) {
  if (update.sessionUpdate === "agent_message_chunk" && !update.content.text.startsWith("[context]")) chunks.push(update.content.text);
}
const result = await turn.result;
const stopReason = await turn.stopReason;
if (result.stopReason !== stopReason) throw new Error("turn.result and turn.stopReason disagreed");
const streamedText = chunks.join("").trimEnd();
if (streamedText !== "hello world") throw new Error(`unexpected streamed text: ${JSON.stringify(chunks)}`);
if (chunks.filter((chunk) => chunk.trim().length > 0).length < 2) throw new Error("token chunks were buffered instead of streamed incrementally");
if (stopReason !== "end_turn") throw new Error(`unexpected stop reason: ${stopReason}`);
if (fetchCalls !== 1) throw new Error(`expected one gateway fetch, got ${fetchCalls}`);
if (requestedModel !== "sdk/browser-test-model") throw new Error(`gateway request used unexpected model: ${requestedModel}`);
if (requestedSessionId !== session.id) throw new Error(`gateway request used unexpected session id: ${requestedSessionId}`);
if (requestedSessionAffinity !== session.id) throw new Error(`gateway request used unexpected session affinity: ${requestedSessionAffinity}`);

await session.close();
let closedSessionRejected = false;
try { session.prompt("must reject"); } catch { closedSessionRejected = true; }
if (!closedSessionRejected) throw new Error("closed session accepted a prompt");
for (let index = 0; index < 200; index++) {
  sessionRecords.set(`listed-session-${String(index).padStart(3, "0")}-${"x".repeat(16)}`, {
    bytes: new Uint8Array(),
    revision: "synthetic",
    updatedAtMs: index,
  });
}
const sessions = await agent.listSessions();
if (!sessions.some((entry) => entry.sessionId === session.id)) throw new Error("persisted session was not listed");
const restored = await agent.openSession(session.id);
if (restored.id !== session.id) throw new Error("opened session id did not match");
if (!restored.history.some((update) => update.sessionUpdate === "agent_message_chunk" && update.content.text.includes("hello world"))) {
  throw new Error("restored session did not replay prior assistant history");
}
failNextRemove = true;
let removeRejected = false;
try { await restored.remove(); } catch { removeRejected = true; }
if (!removeRejected) throw new Error("host session remove failure was accepted");
const retryTurn = restored.prompt("continue after failed removal");
if ((await retryTurn.result).stopReason !== "end_turn") throw new Error("session did not remain active after failed removal");
if (fetchCalls !== 2) throw new Error(`expected one Gateway request per turn, got ${fetchCalls}`);
if (new Set(generationIds).size !== generationIds.length) throw new Error("Gateway responses reused a generation ID");
await restored.remove();
if ((await agent.listSessions()).some((entry) => entry.sessionId === session.id)) throw new Error("removed session was still listed");
const exitCode = await agent.close();
if (exitCode !== 0) throw new Error(`graceful agent close exited with ${exitCode}`);
console.log(`core SDK ACP stream passed: initialize, session/new, structured prompt, and graceful close completed (${session.id})`);
console.log(`streamed ${chunks.length} ACP message chunks: ${chunks.join("")}`);
