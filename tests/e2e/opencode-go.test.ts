// Local HTTP dogfooding proves the actual executable without calling a paid provider.
import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";
import { cleanupIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { createGoProfile, goEnvironment, KEY, HEADER_VALUE, HOST, EXECUTABLE } from "./fixtures/opencode-go-profile";
import { PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY } from "./fixtures/extension-profile";

const IMAGE_FIXTURE = join(import.meta.dir, "fixtures", "placeholder-logo.png");
const IMAGE_FILENAME = "go-image.png";
const SECOND_IMAGE_FILENAME = "go-second-image.png";
const CHANGED_SOURCE = "source changed after capture";
const IMAGE_PROMPT = "Describe the attached local fixture image.";
// A valid tool payload must survive more than one bounded host handoff batch.
const LARGE_TOOL_CONTENT = "é".repeat(200 * 1024);
const CASES = [
  { name: "mixed-case session header", tool: "read_file", sessionHeader: "X-OpenCode-Session", prompt: "Read the fixture file and return the final answer." },
  { name: "read_file with empty reasoning replay", tool: "read_file", sessionHeader: "x-opencode-session", prompt: "Read the fixture file and return the final answer." },
  { name: "large UTF-8 write_file input", tool: "write_file", sessionHeader: "x-opencode-session", prompt: "Write the requested large fixture file and return the final answer." },
];
const RESULT = "go-native-local-ok";
const RPC_VERSION = 1;
const JSONRPC_VERSION = "2.0";
const RPC_TIMEOUT_MS = 5_000;
const SCHEMA_OUTPUT_LIMIT = 128;
const SCHEMA_SESSION = "go-schema-conversation";
const SCHEMA_PROVIDER = "opencode-go";
const SCHEMA_MODEL = "deepseek-v4.1-flash";
// A failed prepare must never leave a stream handle that can transmit a credential.
const RPC_ROUTE_CASES = [
  { name: "selected Chat route", wire: SCHEMA_MODEL, admitted: true },
  { name: "unknown route", wire: "unselected-go-model", admitted: false },
];
const UNPREPARED_HANDLE = "prepared-unknown";
const SCHEMA_BASE_PREFIX = "http://";
const SCHEMA_BASE_PATH = "/v1";
const SCHEMA_PROMPT = "Return the fixture answer as JSON.";
const SCHEMA = { type: "object", properties: { answer: { type: "string" } }, required: ["answer"], additionalProperties: false };
const SCHEMA_FORMAT = { name: "fixture_answer", description: "Return a local fixture answer", schema: SCHEMA };
const SCHEMA_OUTPUT = JSON.stringify({ answer: "go-schema-ok" });
const EXECUTABLE_PERMISSION = "extension_execute";
const SETTINGS_RELATIVE_PATH = ".fx/settings.json";
const EXPLICIT_ACTIVATION_CASES = [{ mode: "ask" }, { mode: "auto" }];
const INPUT_TOKENS = 41;
const OUTPUT_TOKENS = 17;
const SESSION_RELATIVE_DIRECTORY = ".fx/sessions";
const SESSION_FILENAME = "session.json";
const TOOL_FILENAME = "go-fixture-data.txt";
const TOOL_CONTENT = "go-real-tool-result";
const TOOL_ID = "go-read-call";
const TIMEOUT_MS = 20_000;
const STREAM_DELAY_MS = 2_000;
const TUI_TIMEOUT_MS = 10_000;
const STREAM_PREFIX = "go-live-first-chunk";
const CANCELLED_TEXT = "System: cancelled";
const STDERR_FILENAME = "go-tui-stderr.log";
const TUI_PROMPT = "Reply through the local Go fixture.";
const FOLLOWUP_PROMPT = "Make one fresh local Go request.";
const NEGATIVE_CASES = ["http-error", "redirect", "lost-finish", "aggregate-tools"].map(mode => ({ mode }));
// Each malformed boundary must fail before native tools can produce a local effect.
const CHAT_TERMINAL_FAILURES = [
  { mode: "conflicting-finish", first: "content_filter", last: "tool_calls", calls: true },
  { mode: "late-tool", first: "tool_calls", last: "tool_calls", calls: true, initialCall: true },
  { mode: "late-content", first: "stop", last: "stop", content: RESULT },
  { mode: "late-reasoning", first: "stop", last: "stop", reasoning: TOOL_CONTENT },
  { mode: "stop-with-call", last: "stop", calls: true },
  { mode: "length-with-call", last: "length", calls: true },
  { mode: "filter-with-call", last: "content_filter", calls: true },
  { mode: "tool-finish-without-call", last: "tool_calls" },
];
const CHAT_WRITE_TOOL = "write_file";
const CHAT_FAILURE = "ExtensionRpcFailed";
const CHAT_FAILURE_EXIT = 1;
const CHAT_SUCCESS_EXIT = 0;
const CHAT_NON_TOOL_STOPS = ["length", "content_filter"];
const CHAT_LENGTH_FINISH = "length";
const CHAT_LENGTH_NOTICE = "response hit provider length limit";
const CHAT_FILTER_ERROR = "ModelError";
const GO_MANIFEST_FILENAME = "extension.json";
// The curated choices must preserve native tool continuation without borrowing another provider's preferences.
const CURATED_MODELS = [
  { id: "deepseek-flash", wire: "deepseek-v4.1-flash", api: "chat", effort: "max", efforts: ["low", "high", "max"] },
  { id: "glm-5.3", wire: "glm-5.3", api: "chat", effort: "max", efforts: ["low", "high", "max"] },
  { id: "glm-5.3-flash", wire: "glm-5.3-flash", api: "chat", effort: "max", efforts: ["low", "high", "max"] },
  { id: "grok-4.7", wire: "grok-4.7", api: "responses", effort: "xhigh", efforts: ["low", "medium", "high", "xhigh"] },
  { id: "hy4-preview", wire: "hy4-preview", api: "chat", effort: "none", efforts: ["none", "high"] },
  { id: "kimi-k3", wire: "kimi-k3", api: "chat", effort: "max", efforts: ["max"] },
  { id: "longcat-2.5-preview-free", wire: "longcat-2.5-preview-free", api: "chat", effort: undefined, efforts: [] },
  { id: "mimo-v2.6-flash", wire: "mimo-v2.6-flash", api: "chat", effort: undefined, efforts: [] },
  { id: "mimo-v2.6-pro", wire: "mimo-v2.6-pro", api: "chat", effort: undefined, efforts: [] },
  { id: "muse-spark-1.3-contributor", wire: "muse-spark-1.3-contributor", api: "responses", effort: "minimal", efforts: ["minimal", "low", "medium", "high", "xhigh"] },
  { id: "qwen3.8-flash", wire: "qwen3.8-flash", api: "messages", effort: "medium", efforts: ["low", "medium", "xhigh"] },
  { id: "qwen3.8-max", wire: "qwen3.8-max", api: "messages", effort: "xhigh", efforts: ["low", "medium", "xhigh"] },
  { id: "space-bunny", wire: "space-bunny", api: "chat", effort: "medium", efforts: ["low", "medium", "high", "xhigh", "max"] },
];
const CURATED_PROVIDER_PREFIX = "opencode-go/";
const BUILTIN_PREFERENCES = { gateway: "openai/gpt-5.6-sol", codex: "gpt-6.1-sol", grok: "grok-4.7" };
const ENDPOINT_CASES = [
  { name: "bracketed IPv6", hostname: "::1", authority: "[::1]", basePath: "/v1", query: "", expectedTarget: "/v1/chat/completions" },
  { name: "mixed-case localhost", hostname: HOST, authority: "LOCALHOST", basePath: "/v1", query: "", expectedTarget: "/v1/chat/completions" },
  { name: "escaped path and query", hostname: HOST, authority: HOST, basePath: "/tenant%2Fone/v1/", query: "?api-version=fixture%2Freview&route=%2Ftenant", expectedTarget: "/tenant%2Fone/v1/chat/completions?api-version=fixture%2Freview&route=%2Ftenant" },
];
const LARGE_ARGUMENT_BYTES = 600 * 1024;
const ERROR_BODY = "untrusted-go-error-body";
const RESPONSES_MODELS = [
  { id: "grok-4.7", effort: "xhigh", efforts: ["low", "medium", "high", "xhigh"] },
  { id: "muse-spark-1.3-contributor", effort: "minimal", efforts: ["minimal", "low", "medium", "high", "xhigh"] },
];
const RESPONSES_REASONING = { type: "reasoning", id: "reasoning-fixture", encrypted_content: "opaque-fixture-ciphertext", summary: [] };
const RESPONSES_ITEM_ID = "function-item-fixture";
const RESPONSES_REASONING_TEXT = "Private fixture reasoning.";
const RESPONSES_FRAGMENT_BYTES = 7;
const RESPONSES_SYSTEM_POLICY = "Fixture policy";
const RESPONSES_DEVELOPER_POLICY = "Fixture developer policy";
const RESPONSES_HISTORY_TEXT = "Canonical history";
const RESPONSES_FINAL_HISTORY_TEXT = "Prior final answer";
const RESPONSES_PREAMBLE = "I will read the fixture before answering.";
const RESPONSES_TEXT_TOOL_OUTPUT = RESPONSES_PREAMBLE + "\n\n" + RESULT;
const RESPONSES_PHASE_ERROR = "Fixture rejected missing commentary phase or invalid continuation order";
const RESPONSES_COMMENTARY_PHASE = "commentary";
const RESPONSES_CALL_OUTPUT_INDEX = 2;
const RESPONSES_HISTORY_CALL = { id: "history-call", name: "history_tool", arguments_json: "{}" };
const RESPONSES_FUNCTION = { name: "declared_tool", description: "Fixture tool", inputSchema: SCHEMA };
const RESPONSES_FAILURES = ["lost-completion", "truncated-completion", "failed", "incomplete", "wrong-status", "provider-error", "conflicting-id", "wrong-item-id", "bad-arguments", "missing-terminal-call", "replay-injection", "negative-usage", "unfinished-item", "completed-with-error", "empty-call-id", "duplicate-call-id", "undeclared-call", "argument-mismatch"];
const MESSAGES_MODELS = [
  { id: "qwen3.8-flash", effort: "medium", efforts: ["low", "medium", "xhigh"] },
  { id: "qwen3.8-max", effort: "xhigh", efforts: ["low", "medium", "xhigh"] },
];
const MESSAGES_OUTPUT_CAP = 131072;
const MESSAGES_VERSION = "2023-06-01";
const MESSAGES_THINKING = { type: "thinking", thinking: RESPONSES_REASONING_TEXT, signature: "opaque-fixture-signature" };
const MESSAGES_REDACTED = { type: "redacted_thinking", data: "opaque-fixture-redacted" };
// Unequal snapshots reject stale-input reuse and additive usage regressions independently.
const MESSAGES_START_INPUT = 23;
const MESSAGES_START_OUTPUT = 3;
const MESSAGES_PRIOR_USAGE = { input_tokens: 31, output_tokens: 11, cache_creation_input_tokens: 2, cache_read_input_tokens: 4 };
const MESSAGES_CACHE_CREATED = 5;
const MESSAGES_CACHE_READ = 7;
const MESSAGES_TOTAL_INPUT = INPUT_TOKENS + MESSAGES_CACHE_CREATED + MESSAGES_CACHE_READ;
const MESSAGES_MAX_INTEGER = "9223372036854775807";
const MESSAGES_FAILURES = ["lost-stop", "truncated-stop", "missing-reason", "unknown-reason", "open-block", "missing-start", "duplicate-start", "wrong-index", "wrong-delta", "late-delta", "reopened-block", "bad-arguments", "duplicate-call-id", "missing-signature", "signature-control", "thinking-after-signature", "replay-injection", "negative-usage", "negative-cache", "cache-without-input", "usage-overflow", "provider-error", "tools-with-end-turn", "tool-reason-without-call", "initial-input-conflict", "signature-limit", "aggregate-replay"];
const MESSAGES_HEADER_CONFLICTS = ["x-api-key", "X-API-Key", "anthropic-version", "ANTHROPIC-VERSION", "Authorization"];
const TTY_APIS = ["chat", "responses", "messages"];
const API_PATHS: Record<string, string> = { chat: "/v1/chat/completions", responses: "/v1/responses", messages: "/v1/messages" };
const SWITCH_MODELS = [CURATED_MODELS[0], CURATED_MODELS[3], CURATED_MODELS[10]];
const SWITCH_PAIRS = SWITCH_MODELS.flatMap(from => SWITCH_MODELS.filter(to => to.api !== from.api).map(to => ({ from, to })));
const SWITCH_EFFORT = "low";
const PICKER_COMMAND = "/model";
const PICKER_HEIGHT = 60;
const PICKER_DEEPSEEK_LABEL = "opencode-go/deepseek-flash";
const ALL_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
const REPLAY_BOUNDARY_ITEMS = 129;
const LEGACY_REASONING = "legacy-chat-reasoning";
const UNSUPPORTED_EFFORT = "unselected-effort";
const REMOVED_WIRE = "deepseek-v4-pro";
const CATALOG_CALL_OUTPUT_INDEX = 1;
// Shared semantic labels keep catalog fixtures aligned without hidden per-scenario defaults.
const CATALOG_FALLBACK_EFFORT = "max";
const CATALOG_PERMISSION_MODE = "auto";
const CATALOG_EXECUTABLE_ALLOW = "allow";
const CATALOG_READ_TOOL = "read_file";
const CATALOG_CHAT_API = "chat";
const CATALOG_RESPONSES_API = "responses";
const CATALOG_MESSAGES_API = "messages";
const CATALOG_CHAT_REPLAY_API = "chat_completions";
const CATALOG_TOOL_BLOCK_INDEX = 2;
const CATALOG_MESSAGES_TOOL_FINISH = "tool_use";
const CATALOG_MESSAGES_STOP_FINISH = "end_turn";
const CATALOG_CHAT_TOOL_FINISH = "tool_calls";
const CATALOG_CHAT_STOP_FINISH = "stop";
const CATALOG_FUNCTION_TYPE = "function";
const CATALOG_CALL_TYPE = "function_call";
const CATALOG_CALL_COMPLETED = "completed";
const CATALOG_CALL_IN_PROGRESS = "in_progress";
const CATALOG_RESPONSES_EVENTS = {
  call_added: "response.output_item.added",
  arguments_delta: "response.function_call_arguments.delta",
  call_done: "response.output_item.done",
  text_delta: "response.output_text.delta",
};
const CATALOG_RPC_INITIALIZE = "initialize";
const CATALOG_RPC_PREPARE = "provider.prepare";
const CATALOG_RPC_STREAM = "provider.stream";
const CATALOG_RPC_FAILURE = "Provider request failed";
const CATALOG_ASSISTANT_ROLE = "assistant";
const CATALOG_DEEPSEEK_MATCH = "deepseek";
const CATALOG_COMMAND_ASK = "ask";
const CATALOG_COMMAND_MODELS = "models";
const CATALOG_JSON_FLAG = "--json";
const CATALOG_NO_SAVE_FLAG = "--no-save";
const CATALOG_RESUME_FLAG = "--resume";
const CATALOG_QUIT_COMMAND = "/quit";
const CATALOG_STARTUP_HINT = "Run /help";
const CATALOG_PICKER_DOWN = "Down";
const CATALOG_PICKER_UP = "Up";
const CATALOG_PICKER_ENTER = "Enter";
const CATALOG_SHOW_ONBOARDING = "0";

const tuiTest = tmuxAvailable() ? test : test.skip;
const homes: string[] = [];
afterEach(() => { for (const home of homes.splice(0)) cleanupIsolatedTestHome(home); });

// The server is a bounded in-process peer; every reply uses the public chat SSE shape.
function streamReply(chunks: unknown[]): Response {
  const body = chunks.map(chunk => "data: " + JSON.stringify(chunk) + "\n\n").join("") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

// Product discovery supplies every route; private profiles change only selected preferences.
function responsesProfile(port: number, model = RESPONSES_MODELS[0]): string {
  const home = createGoProfile(port);
  const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
  const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
  settings.models.extension = CURATED_PROVIDER_PREFIX + model.id;
  settings.effort = model.effort;
  writeFileSync(settingsPath, JSON.stringify(settings));
  return home;
}

// The selected Qwen output cap comes from the same shipped catalog as native discovery.
function messagesProfile(port: number, model = MESSAGES_MODELS[0]): string {
  return responsesProfile(port, model);
}

// Small network fragments prove SSE framing against actual sockets, including CRLF boundaries.
function responsesReply(chunks: unknown[], fragmented = false): Response {
  const bytes = new TextEncoder().encode(chunks.map(chunk => "data: " + JSON.stringify(chunk) + "\r\n\r\n").join(""));
  return new Response(fragmented ? new ReadableStream({ start(controller) {
    for (let offset = 0; offset < bytes.length; offset += RESPONSES_FRAGMENT_BYTES) controller.enqueue(bytes.slice(offset, offset + RESPONSES_FRAGMENT_BYTES));
    controller.close();
  } }) : bytes, { headers: { "content-type": "text/event-stream" } });
}

// Final snapshots are mandatory evidence for every streamed call and encrypted reasoning item.
function responsesCompleted(output: unknown[] = [], status = "completed", usage = { input_tokens: INPUT_TOKENS, output_tokens: OUTPUT_TOKENS }) {
  return { type: "response.completed", response: { status, output, usage } };
}

// Messages terminal evidence must remain separate from the typed block lifecycle.
function messagesStart() {
  return { type: "message_start", message: { type: "message", role: "assistant", content: [],
    usage: { input_tokens: MESSAGES_START_INPUT, output_tokens: MESSAGES_START_OUTPUT } } };
}

// Cumulative output usage replaces the start count instead of summing streaming snapshots.
function messagesTerminal(reason = "end_turn") {
  return [{ type: "message_delta", delta: { stop_reason: reason }, usage: { input_tokens: INPUT_TOKENS, output_tokens: OUTPUT_TOKENS,
    cache_creation_input_tokens: MESSAGES_CACHE_CREATED, cache_read_input_tokens: MESSAGES_CACHE_READ } }, { type: "message_stop" }];
}

// Indexed typed blocks expose API gaps while canonical calls retain dense native indexes.
function messagesText(text: string, index = 0) {
  return [{ type: "content_block_start", index, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index, delta: { type: "text_delta", text } }, { type: "content_block_stop", index }];
}

// Typed thinking fragments are replayed only after both the block and message close.
function messagesThinking() {
  const midpoint = Math.floor(MESSAGES_THINKING.signature.length / 2);
  return [{ type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: MESSAGES_THINKING.thinking } },
    ...[MESSAGES_THINKING.signature.slice(0, midpoint), MESSAGES_THINKING.signature.slice(midpoint)].map(signature => ({ type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature } })),
    { type: "content_block_stop", index: 0 }, { type: "content_block_start", index: 1, content_block: MESSAGES_REDACTED }, { type: "content_block_stop", index: 1 }];
}

// Fragmented JSON reaches the actual socket worker before native tool execution is permitted.
function messagesTool(argumentsJson: string, index = 0, name = "write_file", id = TOOL_ID) {
  const midpoint = Math.floor(argumentsJson.length / 2);
  return [{ type: "content_block_start", index, content_block: { type: "tool_use", id, name, input: {} } },
    ...[argumentsJson.slice(0, midpoint), argumentsJson.slice(midpoint)].map(partial_json => ({ type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json } })),
    { type: "content_block_stop", index }];
}

// Distinct HTTP envelopes exercise native read_file without hiding wrong catalog routing.
function catalogReply(api: string, home: string, tool: boolean): Response {
  const argumentsJson = JSON.stringify({ path: join(home, TOOL_FILENAME) });
  if (api === CATALOG_MESSAGES_API) return responsesReply([messagesStart(), ...(tool ? [...messagesThinking(), ...messagesTool(argumentsJson, CATALOG_TOOL_BLOCK_INDEX, CATALOG_READ_TOOL)] : messagesText(RESULT)), ...messagesTerminal(tool ? CATALOG_MESSAGES_TOOL_FINISH : CATALOG_MESSAGES_STOP_FINISH)]);
  if (api === CATALOG_RESPONSES_API) {
    const call = { type: CATALOG_CALL_TYPE, id: RESPONSES_ITEM_ID, call_id: TOOL_ID, name: CATALOG_READ_TOOL, arguments: argumentsJson, status: CATALOG_CALL_COMPLETED };
    return responsesReply(tool ? [
      { type: CATALOG_RESPONSES_EVENTS.call_added, output_index: CATALOG_CALL_OUTPUT_INDEX, item: { ...call, arguments: "", status: CATALOG_CALL_IN_PROGRESS } },
      { type: CATALOG_RESPONSES_EVENTS.arguments_delta, output_index: CATALOG_CALL_OUTPUT_INDEX, item_id: call.id, delta: call.arguments },
      { type: CATALOG_RESPONSES_EVENTS.call_done, output_index: CATALOG_CALL_OUTPUT_INDEX, item: call }, responsesCompleted([RESPONSES_REASONING, call]),
    ] : [{ type: CATALOG_RESPONSES_EVENTS.text_delta, delta: RESULT }, responsesCompleted()]);
  }
  return streamReply([{ choices: [{ index: 0, delta: tool ? { reasoning_content: RESPONSES_REASONING_TEXT, tool_calls: [{ index: 0, id: TOOL_ID, function: { name: CATALOG_READ_TOOL, arguments: argumentsJson } }] } : { content: RESULT }, finish_reason: tool ? CATALOG_CHAT_TOOL_FINISH : CATALOG_CHAT_STOP_FINISH }] }]);
}

// Effort placement belongs to the HTTP API, while admission belongs to the wire metadata.
function projectedEffort(body: any, api: string): string | undefined {
  return api === CATALOG_MESSAGES_API ? body.output_config?.effort : api === CATALOG_RESPONSES_API ? body.reasoning?.effort : body.reasoning_effort;
}

// Native nullable request fields exercise schema, role merging and family-bound replay via RPC.
function messagesRequest(state: string | null = null) {
  const request = responseRequest(state);
  request.reasoning_effort = MESSAGES_MODELS[0].effort;
  request.tool_choice = "auto";
  request.messages.splice(2, 0, { role: "user", content: SCHEMA_PROMPT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null });
  request.messages.push({ role: "user", content: TUI_PROMPT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null });
  return request;
}

// Exercising the public provider RPC covers declared schemas unavailable through the CLI.
function providerRpc() {
  const child = Bun.spawn([EXECUTABLE], { stdin: "pipe", stdout: "pipe", stderr: "pipe", env: {} });
  const reader = child.stdout.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let requestId = 0;
  async function rpc(method: string, params: unknown): Promise<any> {
    const id = ++requestId;
    child.stdin.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, id, method, params }) + "\n");
    let timer: ReturnType<typeof setTimeout> | undefined;
    const reply = async () => { for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        const frame = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        if (frame.id !== id) continue;
        if (frame.error) throw new Error(frame.error.message);
        return frame.result;
      }
      const next = await reader.read();
      if (next.done) throw new Error("Provider exited before reply");
      buffer += decoder.decode(next.value, { stream: true });
    } };
    try { return await Promise.race([reply(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Provider RPC deadline")), RPC_TIMEOUT_MS); })]); }
    finally { clearTimeout(timer); }
  }
  return { rpc, async close() {
    if (child.exitCode === null) { await rpc("shutdown", {}); child.stdin.end(); }
    expect(await child.exited).toBe(0);
    expect(await new Response(child.stderr).text()).toBe("");
    await reader.cancel();
  } };
}

// Native nullable fields stay explicit so fixture requests follow the host projection contract.
function responseRequest(state: string | null = null) {
  return { messages: [{ role: "system", content: RESPONSES_SYSTEM_POLICY, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null },
    { role: "developer", content: RESPONSES_DEVELOPER_POLICY, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null },
    { role: "assistant", content: RESPONSES_HISTORY_TEXT, images: [], tool_call_id: null, tool_calls: [RESPONSES_HISTORY_CALL], provider_state_json: state },
    { role: "tool", content: TOOL_CONTENT, images: [], tool_call_id: RESPONSES_HISTORY_CALL.id, tool_calls: [], provider_state_json: null },
    { role: "assistant", content: RESPONSES_FINAL_HISTORY_TEXT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null },
    { role: "user", content: SCHEMA_PROMPT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null }],
    functions: [RESPONSES_FUNCTION], additional_functions: [RESPONSES_FUNCTION], dynamic_functions: [RESPONSES_FUNCTION], reasoning_effort: "high", max_output_tokens: SCHEMA_OUTPUT_LIMIT,
    tool_choice: "none", parallel_tool_calls: false, response_format: SCHEMA_FORMAT };
}

describe("native OpenCode Go extension", () => {
  // Both Qwen identities exercise the full native tool runtime with immutable image admission.
  test.each(MESSAGES_MODELS)("Messages $id preserves fragmented thinking, native tools and image snapshots", async model => {
    const requests: any[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      requests.push({ body, path: new URL(request.url).pathname, key: request.headers.get("x-api-key"), version: request.headers.get("anthropic-version"), authorization: request.headers.get("authorization") });
      if (requests.length === 1) {
        writeFileSync(join(home, IMAGE_FILENAME), CHANGED_SOURCE);
        const thinking = messagesThinking();
        // Qwen documents empty signatures; opaque nonempty replay remains a separate grammar case.
        if (model.id === MESSAGES_MODELS[0].id) for (const event of thinking) if (event.type === "content_block_delta" && event.delta?.type === "signature_delta") event.delta.signature = "";
        return responsesReply([messagesStart(), ...thinking, ...messagesText(RESPONSES_PREAMBLE, 2),
          ...messagesTool(JSON.stringify({ path: join(home, TOOL_FILENAME) }), 3, "read_file"), ...messagesTerminal("tool_use")], true);
      }
      return responsesReply([messagesStart(), ...messagesText(RESULT), ...messagesTerminal()], true);
    } });
    home = messagesProfile(server.port, model);
    homes.push(home);
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const image = join(home, IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, image);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--image", image, IMAGE_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      const output = JSON.parse(stdout);
      expect(output.output).toBe(RESPONSES_TEXT_TOOL_OUTPUT);
      expect(requests).toHaveLength(2);
      for (const { body, path, key, version, authorization } of requests) {
        expect(path).toBe("/v1/messages");
        expect(key).toBe(KEY);
        expect(version).toBe(MESSAGES_VERSION);
        expect(authorization).toBeNull();
        expect(body.max_tokens).toBe(MESSAGES_OUTPUT_CAP);
        expect(body.model).toBe(model.id);
        expect(body.output_config).toEqual({ effort: model.effort });
        expect(body.system.every((item: any) => item.type === "text")).toBe(true);
        expect(body.messages.every((item: any) => item.role === "user" || item.role === "assistant")).toBe(true);
        expect(body.messages.flatMap((item: any) => item.content).find((item: any) => item.type === "image")).toEqual({ type: "image", source: { type: "base64", media_type: "image/png", data: readFileSync(IMAGE_FIXTURE).toString("base64") } });
        expect(body.tools.find((tool: any) => tool.name === "read_file").input_schema.properties.path).toBeTruthy();
        expect(body.reasoning_effort).toBeUndefined();
        expect(body.stream_options).toBeUndefined();
      }
      const assistant = requests[1].body.messages.find((item: any) => item.role === "assistant");
      expect(assistant.content).toEqual([{ ...MESSAGES_THINKING, signature: model.id === MESSAGES_MODELS[0].id ? "" : MESSAGES_THINKING.signature }, MESSAGES_REDACTED,
        { type: "text", text: RESPONSES_PREAMBLE }, { type: "tool_use", id: TOOL_ID, name: "read_file", input: { path: join(home, TOOL_FILENAME) } }]);
      expect(requests[1].body.messages.flatMap((item: any) => item.content).find((item: any) => item.type === "tool_result")).toMatchObject({ type: "tool_result", tool_use_id: TOOL_ID });
      expect(requests[1].body.messages.flatMap((item: any) => item.content).find((item: any) => item.type === "tool_result").content).toContain(TOOL_CONTENT);
      const saved = JSON.parse(readFileSync(join(home, SESSION_RELATIVE_DIRECTORY, output.session_id, SESSION_FILENAME), "utf8"));
      expect(saved.total_input_tokens).toBe(MESSAGES_TOTAL_INPUT);
      expect(saved.total_output_tokens).toBe(OUTPUT_TOKENS);
      expect(readFileSync(image, "utf8")).toBe(CHANGED_SOURCE);
      expect(JSON.stringify(requests)).not.toContain(image);
      expect(JSON.stringify(requests)).not.toContain("snapshot_path");
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // RPC covers schema fields, model limits and replay boundaries unavailable through native CLI flags.
  test("Messages schema, effort, grouped history and replay use the actual provider RPC", async () => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      return responsesReply([messagesStart(), ...messagesText(SCHEMA_OUTPUT),
        { type: "message_delta", delta: { stop_reason: null }, usage: MESSAGES_PRIOR_USAGE }, ...messagesTerminal()]);
    } });
    const peer = providerRpc();
    const prepare = (request: any, cap: number | null = MESSAGES_OUTPUT_CAP) => peer.rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: MESSAGES_MODELS[0].id, max_output_tokens: cap }, request });
    try {
      await peer.rpc("initialize", { version: RPC_VERSION });
      const states = [null, JSON.stringify([{ reasoning_content: "legacy-chat" }]), JSON.stringify([{ api: "responses", items: [RESPONSES_REASONING] }]),
        JSON.stringify([{ api: "messages", items: [MESSAGES_THINKING, MESSAGES_REDACTED] }]), JSON.stringify([{ api: "messages", items: [{ ...MESSAGES_THINKING, signature: "" }] }])];
      for (const state of states) {
        const prepared = await prepare(messagesRequest(state));
        const completed = await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(completed.content).toBe(SCHEMA_OUTPUT);
        expect(completed.finish_reason).toBe("stop");
        expect(completed.usage).toEqual({ input_tokens: MESSAGES_TOTAL_INPUT, output_tokens: OUTPUT_TOKENS });
        const body = bodies.at(-1);
        expect(body.output_config).toEqual({ effort: MESSAGES_MODELS[0].effort, format: { type: "json_schema", schema: SCHEMA } });
        expect(body.max_tokens).toBe(SCHEMA_OUTPUT_LIMIT);
        expect(body.system).toEqual([{ type: "text", text: RESPONSES_SYSTEM_POLICY }, { type: "text", text: RESPONSES_DEVELOPER_POLICY }]);
        expect(body.messages.map((item: any) => item.role)).toEqual(["user", "assistant", "user", "assistant", "user"]);
        expect(body.messages.at(-1).content).toEqual([{ type: "text", text: SCHEMA_PROMPT }, { type: "text", text: TUI_PROMPT }]);
        expect(body.messages[1].content.find((item: any) => item.type === "tool_use")).toEqual({ type: "tool_use", id: RESPONSES_HISTORY_CALL.id, name: RESPONSES_HISTORY_CALL.name, input: {} });
        expect(body.messages[2].content[0]).toEqual({ type: "tool_result", tool_use_id: RESPONSES_HISTORY_CALL.id, content: TOOL_CONTENT });
        expect(body.messages[1].content.filter((item: any) => item.type === "thinking")).toHaveLength(state?.includes('"api":"messages"') ? 1 : 0);
        expect(body.tool_choice).toEqual({ type: "auto", disable_parallel_tool_use: true });
        expect(body.tools).toEqual(Array.from({ length: 3 }, () => ({ name: RESPONSES_FUNCTION.name, description: RESPONSES_FUNCTION.description, input_schema: SCHEMA })));
        expect(body.response_format).toBeUndefined();
        expect(body.parallel_tool_calls).toBeUndefined();
      }
      for (const [choice, parallel, expected] of [["required", false, { type: "any", disable_parallel_tool_use: true }], ["none", false, { type: "none" }], ["auto", true, { type: "auto" }], ["auto", null, { type: "auto" }]]) {
        const prepared = await prepare({ ...messagesRequest(), tool_choice: choice, parallel_tool_calls: parallel, max_output_tokens: null });
        await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(bodies.at(-1).tool_choice).toEqual(expected);
        expect(bodies.at(-1).max_tokens).toBe(MESSAGES_OUTPUT_CAP);
      }
      const grouped = messagesRequest();
      const assistant = grouped.messages.find(item => item.role === "assistant")!;
      assistant.tool_calls.push({ ...RESPONSES_HISTORY_CALL, id: RESPONSES_HISTORY_CALL.id + "-second" });
      grouped.messages.splice(grouped.messages.findIndex(item => item.role === "tool") + 1, 0, { role: "tool", content: TOOL_CONTENT, images: [], tool_call_id: RESPONSES_HISTORY_CALL.id + "-second", tool_calls: [], provider_state_json: null });
      const prepared = await prepare({ ...grouped, reasoning_effort: "low" });
      await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
      expect(bodies.at(-1).messages[2].content.map((item: any) => item.tool_use_id)).toEqual([RESPONSES_HISTORY_CALL.id, RESPONSES_HISTORY_CALL.id + "-second"]);
      expect(bodies.at(-1).output_config.effort).toBe("low");
      for (const state of [JSON.stringify([{ api: "messages", items: [{ type: "tool_use", id: TOOL_ID }] }]), JSON.stringify([{ api: "messages", items: [{ ...MESSAGES_THINKING, role: "system" }] }]), JSON.stringify([{ api: "messages", items: [{ type: "thinking", thinking: "unsigned" }] }]), JSON.stringify([{ api: "messages", items: [{ ...MESSAGES_REDACTED, data: "" }] }])]) await expect(prepare(messagesRequest(state))).rejects.toThrow("Provider request failed");
      for (const effort of ["max", "high", "none", "minimal"]) await expect(prepare({ ...messagesRequest(), reasoning_effort: effort })).rejects.toThrow("Provider request failed");
      for (const limit of [0, -1, MESSAGES_OUTPUT_CAP + 1, 1.5]) await expect(prepare({ ...messagesRequest(), max_output_tokens: limit })).rejects.toThrow("Provider request failed");
      await expect(prepare({ ...messagesRequest(), max_output_tokens: null }, null)).rejects.toThrow("Provider request failed");
      expect(bodies).toHaveLength(states.length + 5);
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Native tool history survives model changes without borrowing another family's opaque replay.
  test("Messages replay remains family-bound when native history switches protocols", async () => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      return new URL(request.url).pathname.endsWith("/responses") ? responsesReply([{ type: "response.output_text.delta", delta: RESULT }, responsesCompleted()])
        : streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    const peer = providerRpc();
    try {
      await peer.rpc("initialize", { version: RPC_VERSION });
      for (const wire of [SCHEMA_MODEL, RESPONSES_MODELS[0].id]) {
        const request = responseRequest(JSON.stringify([{ api: "messages", items: [MESSAGES_THINKING, MESSAGES_REDACTED] }]));
        request.reasoning_effort = wire === SCHEMA_MODEL ? "max" : "high";
        const prepared = await peer.rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: wire }, request });
        const completed = await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(completed.content).toBe(RESULT);
        expect(JSON.stringify(bodies.at(-1))).not.toContain(MESSAGES_THINKING.signature);
        expect(JSON.stringify(bodies.at(-1))).not.toContain(MESSAGES_REDACTED.data);
        expect(JSON.stringify(bodies.at(-1))).toContain(RESPONSES_HISTORY_CALL.id);
        expect(JSON.stringify(bodies.at(-1))).toContain(TOOL_CONTENT);
        expect(JSON.stringify(bodies.at(-1))).toContain(RESPONSES_HISTORY_TEXT);
      }
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Recognized non-tool stops still require message_stop and retain their native finish semantics.
  test.each(["max_tokens", "stop_sequence"])("Messages %s maps a complete terminal reason", async reason => {
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() { return responsesReply([messagesStart(), ...messagesText(RESULT), ...messagesTerminal(reason)]); } });
    const peer = providerRpc();
    try {
      await peer.rpc("initialize", { version: RPC_VERSION });
      const prepared = await peer.rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: MESSAGES_MODELS[0].id, max_output_tokens: MESSAGES_OUTPUT_CAP }, request: messagesRequest() });
      const completed = await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
      expect(completed.content).toBe(RESULT);
      expect(completed.finish_reason).toBe(reason === "max_tokens" ? "length" : "stop");
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Caller bindings cannot override managed Messages authentication or version negotiation.
  test.each(MESSAGES_HEADER_CONFLICTS)("Messages rejects conflicting %s header before HTTP", async header => {
    let requests = 0;
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() { requests++; return responsesReply([messagesStart(), ...messagesTerminal()]); } });
    const peer = providerRpc();
    try {
      await peer.rpc("initialize", { version: RPC_VERSION });
      const prepared = await peer.rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: MESSAGES_MODELS[0].id, max_output_tokens: MESSAGES_OUTPUT_CAP }, request: messagesRequest() });
      await expect(peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION, [header]: HEADER_VALUE }, session_id: SCHEMA_SESSION })).rejects.toThrow("Provider request failed");
      expect(requests).toBe(0);
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Unclosed, cross-typed or malformed blocks never authorize real native filesystem effects.
  test.each(MESSAGES_FAILURES)("Messages %s rejects incomplete or hostile stream", async mode => {
    let requests = 0;
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      const tool = messagesTool(JSON.stringify({ path: join(home, TOOL_FILENAME), content: TOOL_CONTENT }));
      const start = messagesStart();
      const terminal = messagesTerminal("tool_use");
      if (mode === "lost-stop") return responsesReply([start, ...tool, terminal[0]]);
      if (mode === "truncated-stop") return new Response([start, ...tool, terminal[0]].map(event => "data: " + JSON.stringify(event) + "\n\n").join("") + "data: " + JSON.stringify(terminal[1]) + "\n", { headers: { "content-type": "text/event-stream" } });
      if (mode === "missing-reason") return responsesReply([start, ...tool, terminal[1]]);
      if (mode === "unknown-reason") return responsesReply([start, ...tool, ...messagesTerminal("unknown")]);
      if (mode === "open-block") return responsesReply([start, ...tool.slice(0, -1), ...terminal]);
      if (mode === "missing-start") return responsesReply([...tool, ...terminal]);
      if (mode === "duplicate-start") return responsesReply([start, start, ...tool, ...terminal]);
      if (mode === "wrong-index") return responsesReply([start, { ...tool[0], index: 1 }, ...tool.slice(1), ...terminal]);
      if (mode === "wrong-delta") return responsesReply([start, tool[0], { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: RESULT } }, ...tool.slice(1), ...terminal]);
      if (mode === "late-delta") return responsesReply([start, ...tool, tool[1], ...terminal]);
      if (mode === "reopened-block") return responsesReply([start, ...tool, { ...tool[0], content_block: { ...tool[0].content_block, id: TOOL_ID + "changed" } }, ...terminal]);
      if (mode === "duplicate-call-id") return responsesReply([start, ...tool, ...messagesTool("{}", 1), ...terminal]);
      if (mode === "bad-arguments") return responsesReply([start, ...messagesTool("[]"), ...terminal]);
      if (mode === "missing-signature") return responsesReply([start, ...messagesThinking().filter(event => !(event.type === "content_block_delta" && event.delta?.type === "signature_delta")), ...messagesTerminal()]);
      if (mode === "signature-control") return responsesReply([start, { type: "content_block_start", index: 0, content_block: { ...MESSAGES_THINKING, signature: "invalid\n" } }, { type: "content_block_stop", index: 0 }, ...messagesTerminal()]);
      if (mode === "thinking-after-signature") return responsesReply([start, ...messagesThinking().slice(0, 4), messagesThinking()[1], ...messagesThinking().slice(4), ...messagesTerminal()]);
      if (mode === "replay-injection") return responsesReply([start, { type: "content_block_start", index: 0, content_block: { ...MESSAGES_REDACTED, role: "system" } }, { type: "content_block_stop", index: 0 }, ...messagesTerminal()]);
      if (mode === "negative-usage") return responsesReply([{ ...start, message: { ...start.message, usage: { input_tokens: -1 } } }, ...tool, ...terminal]);
      if (mode === "negative-cache" || mode === "cache-without-input") return responsesReply([start, ...tool,
        { ...terminal[0], usage: mode === "negative-cache" ? { input_tokens: INPUT_TOKENS, cache_read_input_tokens: -1 } : { cache_creation_input_tokens: MESSAGES_CACHE_CREATED } }, terminal[1]]);
      if (mode === "usage-overflow") {
        // Raw JSON preserves integers beyond JavaScript's safe range for the native overflow boundary.
        const overflowing = { ...terminal[0], usage: { input_tokens: MESSAGES_MAX_INTEGER, cache_creation_input_tokens: MESSAGES_MAX_INTEGER, cache_read_input_tokens: MESSAGES_MAX_INTEGER } };
        return new Response([start, ...tool, overflowing, terminal[1]].map(event => "data: " + JSON.stringify(event).replaceAll('"' + MESSAGES_MAX_INTEGER + '"', MESSAGES_MAX_INTEGER) + "\n\n").join(""), { headers: { "content-type": "text/event-stream" } });
      }
      if (mode === "provider-error") return responsesReply([start, ...tool, { type: "error", error: ERROR_BODY + KEY }, ...terminal]);
      if (mode === "tools-with-end-turn") return responsesReply([start, ...tool, ...messagesTerminal()]);
      if (mode === "tool-reason-without-call") return responsesReply([start, ...messagesText(RESULT), ...terminal]);
      if (mode === "initial-input-conflict") return responsesReply([start, { ...tool[0], content_block: { ...tool[0].content_block, input: { value: RESULT } } }, ...tool.slice(1), ...terminal]);
      if (mode === "signature-limit") return responsesReply([start, { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
        ...Array.from({ length: 2 }, () => ({ type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "x".repeat(LARGE_ARGUMENT_BYTES) } })), { type: "content_block_stop", index: 0 }, ...messagesTerminal()]);
      return responsesReply([start, ...Array.from({ length: 15 }, (_, index) => [{ type: "content_block_start", index, content_block: { ...MESSAGES_REDACTED, data: "x".repeat(LARGE_ARGUMENT_BYTES) } }, { type: "content_block_stop", index }]).flat(), ...messagesTerminal()]);
    } });
    home = messagesProfile(server.port);
    homes.push(home);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(1);
      expect(JSON.parse(stdout).error).toBe("ExtensionRpcFailed");
      expect(requests).toBe(1);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stdout + stderr).not.toContain(ERROR_BODY);
      expect(() => readFileSync(join(home, TOOL_FILENAME))).toThrow();
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Both selected Responses identities must preserve real tools, images, replay and persisted usage.
  test.each(RESPONSES_MODELS)("Responses $id completes fragmented reasoning and native tool continuation", async model => {
    const requests: any[] = [];
    let commentaryAccepted = false;
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      requests.push({ body, path: new URL(request.url).pathname, authorization: request.headers.get("authorization") });
      if (requests.length === 1) {
        const call = { type: "function_call", id: RESPONSES_ITEM_ID, call_id: TOOL_ID, name: "read_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME) }), status: "completed" };
        const midpoint = Math.floor(call.arguments.length / 2);
        writeFileSync(join(home, IMAGE_FILENAME), CHANGED_SOURCE);
        return responsesReply([
          { type: "response.reasoning_summary_text.delta", delta: RESPONSES_REASONING_TEXT },
          { type: "response.output_text.delta", delta: RESPONSES_PREAMBLE },
          { type: "response.output_item.added", output_index: RESPONSES_CALL_OUTPUT_INDEX, item: { ...call, arguments: "", status: "in_progress" } },
          { type: "response.function_call_arguments.delta", output_index: RESPONSES_CALL_OUTPUT_INDEX, item_id: call.id, delta: call.arguments.slice(0, midpoint) },
          { type: "response.function_call_arguments.delta", output_index: RESPONSES_CALL_OUTPUT_INDEX, item_id: call.id, delta: call.arguments.slice(midpoint) },
          { type: "response.function_call_arguments.done", output_index: RESPONSES_CALL_OUTPUT_INDEX, item_id: call.id, arguments: call.arguments },
          { type: "response.output_item.done", output_index: RESPONSES_CALL_OUTPUT_INDEX, item: call },
          responsesCompleted([RESPONSES_REASONING, { type: "message", role: "assistant", ...(model.id === RESPONSES_MODELS[1].id ? { phase: RESPONSES_COMMENTARY_PHASE } : {}), content: [{ type: "output_text", text: RESPONSES_PREAMBLE }] }, call]),
        ], true);
      }
      // Contributor rejects an ordinary final-answer message immediately before a function call.
      const commentaryIndex = body.input.findIndex((item: any) => item.role === "assistant" && item.content === RESPONSES_PREAMBLE);
      const callIndex = body.input.findIndex((item: any) => item.type === "function_call");
      const outputIndex = body.input.findIndex((item: any) => item.type === "function_call_output");
      const expectedPhase = model.id === RESPONSES_MODELS[1].id ? RESPONSES_COMMENTARY_PHASE : undefined;
      commentaryAccepted = commentaryIndex >= 0 && body.input[commentaryIndex].phase === expectedPhase
        && callIndex === commentaryIndex + 1 && outputIndex > callIndex && body.input[outputIndex].call_id === body.input[callIndex].call_id;
      if (model.id === RESPONSES_MODELS[1].id && !commentaryAccepted) return new Response(RESPONSES_PHASE_ERROR, { status: 400 });
      return responsesReply([{ type: "response.output_text.delta", delta: RESULT }, responsesCompleted()], true);
    } });
    home = responsesProfile(server.port, model);
    homes.push(home);
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const image = join(home, IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, image);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--image", image, IMAGE_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      const output = JSON.parse(stdout);
      expect(output.output).toBe(RESPONSES_TEXT_TOOL_OUTPUT);
      expect(requests).toHaveLength(2);
      expect(commentaryAccepted).toBe(true);
      for (const { body, path, authorization } of requests) {
        expect(path).toBe("/v1/responses");
        expect(authorization).toBe("Bearer " + KEY);
        expect(body.model).toBe(model.id);
        expect(body.store).toBe(false);
        expect(body.include).toEqual(["reasoning.encrypted_content"]);
        expect(body.reasoning.effort).toBe(model.effort);
        expect(body.messages).toBeUndefined();
        expect(body.stream_options).toBeUndefined();
        const parts = body.input.find((item: any) => Array.isArray(item.content)).content;
        expect(parts.find((part: any) => part.type === "input_image").image_url).toBe("data:image/png;base64," + readFileSync(IMAGE_FIXTURE).toString("base64"));
      }
      const readTool = requests[0].body.tools.find((tool: any) => tool.name === "read_file");
      expect(readTool.parameters.properties.path).toBeTruthy();
      expect(readTool.function).toBeUndefined();
      expect(requests[1].body.input.find((item: any) => item.type === "reasoning")).toEqual(RESPONSES_REASONING);
      expect(requests[1].body.input.find((item: any) => item.type === "function_call").call_id).toBe(TOOL_ID);
      expect(requests[1].body.input.find((item: any) => item.type === "function_call_output").output).toContain(TOOL_CONTENT);
      const saved = JSON.parse(readFileSync(join(home, SESSION_RELATIVE_DIRECTORY, output.session_id, SESSION_FILENAME), "utf8"));
      // The native host currently persists the final request's usage for an entire tool turn.
      expect(saved.total_input_tokens).toBe(INPUT_TOKENS);
      expect(saved.total_output_tokens).toBe(OUTPUT_TOKENS);
      expect(JSON.stringify(requests)).not.toContain(image);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Same-family injection fails at prepare, while foreign replay leaves canonical text available.
  test("Responses schema and replay admission use native provider RPC", async () => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      if (new URL(request.url).pathname.endsWith("/chat/completions")) return streamReply([{ choices: [{ index: 0, delta: { content: SCHEMA_OUTPUT }, finish_reason: "stop" }] }]);
      return responsesReply([{ type: "response.output_text.delta", delta: SCHEMA_OUTPUT }, responsesCompleted()]);
    } });
    const peer = providerRpc();
    const prepare = (request: any, wire = RESPONSES_MODELS[1].id) => peer.rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: wire }, request });
    try {
      await peer.rpc("initialize", { version: RPC_VERSION });
      for (const state of [null, JSON.stringify([{ reasoning_content: "legacy-chat" }]), JSON.stringify([{ api: "messages", items: [{ type: "tool_use", id: "foreign" }] }]), JSON.stringify([{ api: "responses", items: [RESPONSES_REASONING] }])]) {
        const prepared = await prepare(responseRequest(state));
        const completed = await peer.rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(completed.content).toBe(SCHEMA_OUTPUT);
        expect(completed.finish_reason).toBe("stop");
        expect(completed.usage).toEqual({ input_tokens: INPUT_TOKENS, output_tokens: OUTPUT_TOKENS });
        const body = bodies.at(-1);
        expect(body.text.format).toEqual({ type: "json_schema", ...SCHEMA_FORMAT, strict: true });
        expect(body.response_format).toBeUndefined();
        expect(body.max_output_tokens).toBe(SCHEMA_OUTPUT_LIMIT);
        expect(body.input.filter((item: any) => item.role).map((item: any) => item.role)).toEqual(["system", "developer", "assistant", "assistant", "user"]);
        expect(body.input.some((item: any) => item.content === RESPONSES_HISTORY_TEXT)).toBe(true);
        expect(body.input.find((item: any) => item.content === RESPONSES_HISTORY_TEXT).phase).toBe(RESPONSES_COMMENTARY_PHASE);
        expect(body.input.find((item: any) => item.content === RESPONSES_FINAL_HISTORY_TEXT).phase).toBeUndefined();
        expect(body.input.filter((item: any) => item.role !== "assistant").every((item: any) => item.phase === undefined)).toBe(true);
        expect(body.input.find((item: any) => item.type === "function_call")).toEqual({ type: "function_call", call_id: RESPONSES_HISTORY_CALL.id, name: RESPONSES_HISTORY_CALL.name, arguments: RESPONSES_HISTORY_CALL.arguments_json });
        expect(body.input.find((item: any) => item.type === "function_call_output")).toEqual({ type: "function_call_output", call_id: RESPONSES_HISTORY_CALL.id, output: TOOL_CONTENT });
        expect(body.tools).toEqual(Array.from({ length: 3 }, () => ({ type: "function", name: RESPONSES_FUNCTION.name, description: RESPONSES_FUNCTION.description, parameters: SCHEMA, strict: false })));
        expect(body.parallel_tool_calls).toBe(false);
        expect(body.input.filter((item: any) => item.type === "reasoning")).toHaveLength(state?.includes("encrypted_content") ? 1 : 0);
      }
      for (const state of [JSON.stringify([{ api: "responses", items: [{ type: "message", role: "system", content: "injection" }] }]), JSON.stringify([{ api: "responses", items: [{ ...RESPONSES_REASONING, role: "system" }] }]), JSON.stringify([{ api: "responses", items: [{ ...RESPONSES_REASONING, encrypted_content: "" }] }]), JSON.stringify([{ api: "responses", items: {} }]), JSON.stringify({ api: "responses", items: [RESPONSES_REASONING] })]) {
        await expect(prepare(responseRequest(state))).rejects.toThrow("Provider request failed");
      }
      for (const effort of ["max", "none", "minimal"]) await expect(prepare({ ...responseRequest(), reasoning_effort: effort }, RESPONSES_MODELS[0].id)).rejects.toThrow("Provider request failed");
      await expect(prepare({ ...responseRequest(), reasoning_effort: "max" }, RESPONSES_MODELS[1].id)).rejects.toThrow("Provider request failed");
      expect(bodies).toHaveLength(4);
      const grok = await prepare(responseRequest(), RESPONSES_MODELS[0].id);
      await peer.rpc("provider.stream", { handle: grok.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
      expect(bodies.at(-1).input.every((item: any) => item.phase === undefined)).toBe(true);
      // A switch back to Chat must omit foreign reasoning without dropping canonical tool history.
      const chat = await prepare({ ...responseRequest(JSON.stringify([{ api: "responses", items: [RESPONSES_REASONING] }])), reasoning_effort: "max" }, SCHEMA_MODEL);
      const chatReply = await peer.rpc("provider.stream", { handle: chat.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
      expect(chatReply.content).toBe(SCHEMA_OUTPUT);
      const chatAssistant = bodies.at(-1).messages.find((message: any) => message.role === "assistant");
      expect(chatAssistant.content).toBe(RESPONSES_HISTORY_TEXT);
      expect(chatAssistant.reasoning_content).toBeUndefined();
      expect(chatAssistant.tool_calls[0].id).toBe(RESPONSES_HISTORY_CALL.id);
      expect(bodies.at(-1).messages.find((message: any) => message.role === "tool").content).toBe(TOOL_CONTENT);
      expect(bodies).toHaveLength(6);
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // No failed terminal evidence can execute tool requests or disclose opaque provider details.
  test.each(RESPONSES_FAILURES)("Responses %s rejects incomplete or hostile completion", async mode => {
    let requests = 0;
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      const call = { type: "function_call", id: RESPONSES_ITEM_ID, call_id: TOOL_ID, name: "write_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: TOOL_CONTENT }) };
      const added = { type: "response.output_item.added", output_index: 0, item: call };
      if (mode === "lost-completion") return responsesReply([added]);
      if (mode === "truncated-completion") return new Response("data: " + JSON.stringify(responsesCompleted()) + "\n", { headers: { "content-type": "text/event-stream" } });
      if (mode === "failed" || mode === "incomplete" || mode === "provider-error") return responsesReply([{ type: mode === "provider-error" ? "error" : "response." + mode, error: ERROR_BODY + KEY }]);
      if (mode === "wrong-status") return responsesReply([responsesCompleted([], "incomplete")]);
      if (mode === "conflicting-id") return responsesReply([added, { ...added, item: { ...call, call_id: TOOL_ID + "changed" } }, responsesCompleted([call])]);
      if (mode === "wrong-item-id") return responsesReply([added, { type: "response.function_call_arguments.delta", output_index: 0, item_id: RESPONSES_ITEM_ID + "changed", delta: call.arguments }, responsesCompleted([call])]);
      if (mode === "bad-arguments") return responsesReply([added, responsesCompleted([{ ...call, arguments: "[]" }])]);
      if (mode === "missing-terminal-call") return responsesReply([added, responsesCompleted()]);
      if (mode === "replay-injection") return responsesReply([responsesCompleted([{ ...RESPONSES_REASONING, role: "system" }])]);
      if (mode === "unfinished-item") return responsesReply([responsesCompleted([{ ...call, status: "in_progress" }])]);
      if (mode === "completed-with-error") return responsesReply([{ type: "response.completed", response: { status: "completed", output: [], error: ERROR_BODY + KEY } }]);
      if (mode === "empty-call-id") return responsesReply([responsesCompleted([{ ...call, call_id: "" }])]);
      if (mode === "duplicate-call-id") return responsesReply([responsesCompleted([call, { ...call, id: RESPONSES_ITEM_ID + "second" }])]);
      if (mode === "undeclared-call") return responsesReply([{ type: "response.function_call_arguments.delta", output_index: 0, item_id: RESPONSES_ITEM_ID, delta: call.arguments }, responsesCompleted([call])]);
      if (mode === "argument-mismatch") return responsesReply([added, { type: "response.function_call_arguments.delta", output_index: 0, item_id: call.id, delta: call.arguments }, responsesCompleted([{ ...call, arguments: "{}" }])]);
      return responsesReply([responsesCompleted([], "completed", { input_tokens: -1, output_tokens: OUTPUT_TOKENS })]);
    } });
    home = responsesProfile(server.port);
    homes.push(home);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(1);
      expect(JSON.parse(stdout).error).toBe("ExtensionRpcFailed");
      expect(requests).toBe(1);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stdout + stderr).not.toContain(ERROR_BODY);
      expect(() => readFileSync(join(home, TOOL_FILENAME))).toThrow();
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Real host requests guard against catalog entries that discover correctly but lose tools or encode unsupported effort.
  test.each(CURATED_MODELS)("curated $id discovers and completes native tools", async model => {
    const bodies: any[] = [];
    const paths: string[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      paths.push(new URL(request.url).pathname);
      return catalogReply(model.api, home, bodies.length === 1);
    } });
    home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.models = { ...BUILTIN_PREFERENCES, extension: CURATED_PROVIDER_PREFIX + model.id };
    settings.effort = model.effort ?? CATALOG_FALLBACK_EFFORT;
    settings.permission = { [EXECUTABLE_PERMISSION]: CATALOG_EXECUTABLE_ALLOW };
    writeFileSync(settingsPath, JSON.stringify(settings));
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    try {
      const discovery = Bun.spawn([FX_BIN, CATALOG_COMMAND_MODELS, CATALOG_JSON_FLAG], { cwd: home, stdout: "pipe", stderr: "pipe", env: { ...goEnvironment(home), FX_PERMISSION_MODE: CATALOG_PERMISSION_MODE } });
      const [catalog, discoveryError, discoveryCode] = await Promise.all([new Response(discovery.stdout).text(), new Response(discovery.stderr).text(), discovery.exited]);
      expect(discoveryCode, discoveryError).toBe(0);
      const discovered = JSON.parse(catalog).ids;
      expect(discovered).toEqual(CURATED_MODELS.map(choice => CURATED_PROVIDER_PREFIX + choice.id));
      expect(discovered.filter((id: string) => id.includes(CATALOG_DEEPSEEK_MATCH))).toEqual([CURATED_PROVIDER_PREFIX + CURATED_MODELS[0].id]);
      expect(discoveryError).toBe("");
      const child = Bun.spawn([FX_BIN, CATALOG_COMMAND_ASK, CATALOG_JSON_FLAG, CATALOG_NO_SAVE_FLAG, TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: { ...goEnvironment(home), FX_PERMISSION_MODE: CATALOG_PERMISSION_MODE } });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(bodies).toHaveLength(2);
      expect(stderr).toContain(TOOL_FILENAME);
      expect(stderr).not.toMatch(/error|panic|YOLO enabled/i);
      expect(paths).toEqual([API_PATHS[model.api], API_PATHS[model.api]]);
      for (const body of bodies) {
        expect(body.model).toBe(model.wire);
        expect(projectedEffort(body, model.api)).toBe(model.effort);
      }
      expect(JSON.stringify(bodies[1])).toContain(TOOL_CONTENT);
      expect(JSON.stringify(bodies[1])).toContain(TOOL_ID);
      const finalSettings = JSON.parse(readFileSync(settingsPath, "utf8"));
      for (const [provider, preference] of Object.entries(BUILTIN_PREFERENCES)) expect(finalSettings.models[provider]).toBe(preference);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Per-wire metadata admission catches stale global scales before credentials can reach HTTP.
  test("all selected effort controls and removed route are checked through provider RPC", async () => {
    let requests = 0;
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      requests++;
      bodies.push(await request.json());
      const model = CURATED_MODELS.find(item => item.wire === bodies.at(-1).model)!;
      return catalogReply(model.api, "", false);
    } });
    const peer = providerRpc();
    const prepare = (model: typeof CURATED_MODELS[number], effort: string | null) => peer.rpc(CATALOG_RPC_PREPARE, {
      provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH },
      model: { wire_id: model.wire, max_output_tokens: MESSAGES_OUTPUT_CAP }, request: { ...responseRequest(), reasoning_effort: effort, response_format: null } });
    try {
      await peer.rpc(CATALOG_RPC_INITIALIZE, { version: RPC_VERSION });
      for (const model of CURATED_MODELS) {
        for (const effort of [null, ...model.efforts]) {
          const prepared = await prepare(model, effort);
          await peer.rpc(CATALOG_RPC_STREAM, { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
          expect(projectedEffort(bodies.at(-1), model.api)).toBe(effort ?? undefined);
        }
        const before = requests;
        for (const effort of [UNSUPPORTED_EFFORT, ...ALL_EFFORTS.filter(label => !model.efforts.includes(label))]) await expect(prepare(model, effort)).rejects.toThrow(CATALOG_RPC_FAILURE);
        expect(requests).toBe(before);
      }
      await expect(prepare({ ...CURATED_MODELS[0], wire: REMOVED_WIRE }, null)).rejects.toThrow(CATALOG_RPC_FAILURE);
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Legacy state compatibility and bounded envelopes must hold at the actual credential-free prepare boundary.
  test("legacy Chat replay and tagged family bounds preserve canonical history", async () => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      bodies.push(body);
      return catalogReply(CURATED_MODELS.find(model => model.wire === body.model)!.api, "", false);
    } });
    const peer = providerRpc();
    const prepare = (model: typeof CURATED_MODELS[number], state: string) => peer.rpc(CATALOG_RPC_PREPARE, {
      provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH },
      model: { wire_id: model.wire, max_output_tokens: MESSAGES_OUTPUT_CAP },
      request: { ...responseRequest(state), reasoning_effort: SWITCH_EFFORT, response_format: null } });
    const stream = (handle: string) => peer.rpc(CATALOG_RPC_STREAM, { handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
    try {
      await peer.rpc(CATALOG_RPC_INITIALIZE, { version: RPC_VERSION });
      for (const reasoning of ["", LEGACY_REASONING]) {
        const prepared = await prepare(SWITCH_MODELS[0], JSON.stringify([{ reasoning_content: reasoning }]));
        expect((await stream(prepared.handle)).content).toBe(RESULT);
        expect(bodies.at(-1).messages.find((message: any) => message.role === CATALOG_ASSISTANT_ROLE).reasoning_content).toBe(reasoning);
      }
      const before = bodies.length;
      await expect(prepare(SWITCH_MODELS[0], JSON.stringify([{ reasoning_content: INPUT_TOKENS }]))).rejects.toThrow(CATALOG_RPC_FAILURE);
      for (const model of SWITCH_MODELS) {
        const family = model.api === CATALOG_CHAT_API ? CATALOG_CHAT_REPLAY_API : model.api;
        const item = model.api === CATALOG_MESSAGES_API ? MESSAGES_THINKING : RESPONSES_REASONING;
        const tagged = { api: family, items: Array.from({ length: REPLAY_BOUNDARY_ITEMS }, () => item) };
        // Chat already requires exactly one reasoning item; valid typed items isolate the other families' count guard.
        if (model.api !== CATALOG_CHAT_API) await expect(prepare(model, JSON.stringify([tagged]))).rejects.toThrow(CATALOG_RPC_FAILURE);
        // Outer envelope multiplicity is bounded even when both entries claim a foreign family.
        const foreign = { ...tagged, api: model.api === CATALOG_RESPONSES_API ? CATALOG_MESSAGES_API : CATALOG_RESPONSES_API };
        await expect(prepare(model, JSON.stringify([foreign, foreign]))).rejects.toThrow(CATALOG_RPC_FAILURE);
      }
      expect(bodies).toHaveLength(before);
      for (const model of SWITCH_MODELS) {
        const foreign = { api: model.api === CATALOG_RESPONSES_API ? CATALOG_MESSAGES_API : CATALOG_RESPONSES_API, items: { untrusted: LEGACY_REASONING } };
        const prepared = await prepare(model, JSON.stringify([foreign]));
        expect((await stream(prepared.handle)).content).toBe(RESULT);
        const projected = JSON.stringify(bodies.at(-1));
        expect(projected).not.toContain(LEGACY_REASONING);
        for (const text of [RESPONSES_HISTORY_TEXT, TOOL_CONTENT, RESPONSES_HISTORY_CALL.id]) expect(projected).toContain(text);
      }
    } finally { await peer.close(); server.stop(true); }
  }, TIMEOUT_MS);

  // Saved turns preserve portable canonical history across every directed API-family pair.
  test.each(SWITCH_PAIRS)("saved $from.api to $to.api switch keeps text and tools without opaque replay", async ({ from, to }) => {
    const bodies: any[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      bodies.push(body);
      return catalogReply(body.model === from.wire ? from.api : to.api, home, bodies.length === 1);
    } });
    home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.effort = SWITCH_EFFORT;
    settings.permission = { [EXECUTABLE_PERMISSION]: CATALOG_EXECUTABLE_ALLOW };
    writeFileSync(settingsPath, JSON.stringify(settings));
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const run = async (model: string, args: string[], tool: boolean) => {
      const child = Bun.spawn([FX_BIN, CATALOG_COMMAND_ASK, CATALOG_JSON_FLAG, ...args], { cwd: home, stdout: "pipe", stderr: "pipe", env: { ...goEnvironment(home), FX_MODEL: CURATED_PROVIDER_PREFIX + model, FX_PERMISSION_MODE: CATALOG_PERMISSION_MODE } });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      if (tool) {
        expect(stderr).toContain(TOOL_FILENAME);
        expect(stderr).not.toMatch(/error|panic|YOLO enabled/i);
      } else expect(stderr).toBe("");
      expect(JSON.parse(stdout).output).toBe(RESULT);
      return JSON.parse(stdout);
    };
    try {
      const first = await run(from.id, [TUI_PROMPT], true);
      const resumed = await run(to.id, [CATALOG_RESUME_FLAG, first.session_id, FOLLOWUP_PROMPT], false);
      expect(resumed.session_id).toBe(first.session_id);
      expect(bodies).toHaveLength(3);
      expect(bodies[2].model).toBe(to.wire);
      const projected = JSON.stringify(bodies[2]);
      for (const text of [TUI_PROMPT, RESULT, FOLLOWUP_PROMPT, TOOL_CONTENT, TOOL_ID]) expect(projected).toContain(text);
      for (const opaque of [RESPONSES_REASONING.encrypted_content, MESSAGES_THINKING.signature, MESSAGES_REDACTED.data, RESPONSES_REASONING_TEXT]) expect(projected).not.toContain(opaque);
      const saved = JSON.parse(readFileSync(join(home, SESSION_RELATIVE_DIRECTORY, resumed.session_id, SESSION_FILENAME), "utf8"));
      expect(JSON.stringify(saved)).not.toContain(RESPONSES_REASONING.encrypted_content);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native discovery and terminal selection must agree without creating a second DeepSeek alias.
  tuiTest("real TTY picker exposes the approved catalog and persists an actual selection", async () => {
    let requests = 0;
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() { requests++; return catalogReply(CATALOG_CHAT_API, "", false); } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.models = { ...BUILTIN_PREFERENCES, extension: CURATED_PROVIDER_PREFIX + CURATED_MODELS[0].id };
    settings.permission = { [EXECUTABLE_PERMISSION]: CATALOG_EXECUTABLE_ALLOW };
    writeFileSync(settingsPath, JSON.stringify(settings));
    const stderrPath = join(home, STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true, height: PICKER_HEIGHT,
        env: { ...goEnvironment(home), FX_PERMISSION_MODE: CATALOG_PERMISSION_MODE, FX_SKIP_ONBOARDING: CATALOG_SHOW_ONBOARDING } });
      await session.waitForText(CATALOG_STARTUP_HINT, TUI_TIMEOUT_MS);
      await session.sendText(PICKER_COMMAND);
      const pane = await session.waitForText(PICKER_DEEPSEEK_LABEL, TUI_TIMEOUT_MS);
      expect(pane.split(PICKER_DEEPSEEK_LABEL)).toHaveLength(2);
      expect(pane).not.toContain(REMOVED_WIRE);
      const views = [pane];
      for (const _ of CURATED_MODELS.slice(1)) {
        await session.sendKeys(CATALOG_PICKER_DOWN);
        views.push(await session.capturePane());
      }
      for (const model of CURATED_MODELS) expect(views.join("\n")).toContain(CURATED_PROVIDER_PREFIX + model.id);
      expect(requests).toBe(0);
      for (const _ of CURATED_MODELS.slice(1)) await session.sendKeys(CATALOG_PICKER_UP);
      await session.sendKeys(CATALOG_PICKER_DOWN);
      await session.sendKeys(CATALOG_PICKER_ENTER);
      await session.waitForText(/\blow\b/i, TUI_TIMEOUT_MS);
      await session.sendKeys(CATALOG_PICKER_ENTER);
      await session.sendText(TUI_PROMPT);
      await session.waitForText(RESULT, TUI_TIMEOUT_MS);
      const selected = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(selected.models.extension).toBe(CURATED_PROVIDER_PREFIX + CURATED_MODELS[1].id);
      for (const [provider, preference] of Object.entries(BUILTIN_PREFERENCES)) expect(selected.models[provider]).toBe(preference);
      expect(requests).toBe(1);
      await session.sendText(CATALOG_QUIT_COMMAND);
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally { await session?.kill(); server.stop(true); }
  }, TIMEOUT_MS);

  // Native request delivery protects accepted endpoints from adapter-specific URI rewriting.
  test.each(ENDPOINT_CASES)("configured loopback endpoint preserves $name", async scenario => {
    const targets: string[] = [];
    const server = Bun.serve({ hostname: scenario.hostname, port: 0, fetch(request) {
      const url = new URL(request.url);
      targets.push(url.pathname + url.search);
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const manifestPath = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, GO_MANIFEST_FILENAME);
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.providers[0].base_url = `${SCHEMA_BASE_PREFIX}${scenario.authority}:${server.port}${scenario.basePath}${scenario.query}`;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr, targets })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(targets).toEqual([scenario.expectedTarget]);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Exact host-action authority must not disable native permission policy for file tools.
  test.each(EXPLICIT_ACTIVATION_CASES)("explicit native executable allow works under $mode", async ({ mode }) => {
    let requests = 0;
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.permission = { [EXECUTABLE_PERMISSION]: "allow" };
    writeFileSync(settingsPath, JSON.stringify(settings));
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: { ...goEnvironment(home), FX_PERMISSION_MODE: mode } });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(requests).toBe(1);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stderr).not.toContain("YOLO enabled");
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native CLI does not expose response_format; the shipped provider RPC is its public boundary.
  test.each(RPC_ROUTE_CASES)("native provider $name guards HTTP and structured output", async scenario => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      return streamReply([{ choices: [{ index: 0, delta: { content: SCHEMA_OUTPUT }, finish_reason: "stop" }] }]);
    } });
    const child = Bun.spawn([EXECUTABLE], { stdin: "pipe", stdout: "pipe", stderr: "pipe", env: {} });
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let requestId = 0;
    async function rpc(method: string, params: unknown): Promise<any> {
      const id = ++requestId;
      child.stdin.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, id, method, params }) + "\n");
      const reply = async () => {
        for (;;) {
          const newline = buffer.indexOf("\n");
          if (newline >= 0) {
            const frame = JSON.parse(buffer.slice(0, newline));
            buffer = buffer.slice(newline + 1);
            if (frame.id !== id) continue;
            if (frame.error) throw new Error(frame.error.message);
            return frame.result;
          }
          const next = await reader.read();
          if (next.done) throw new Error("Provider exited before reply");
          buffer += decoder.decode(next.value, { stream: true });
        }
      };
      let timer: ReturnType<typeof setTimeout> | undefined;
      try { return await Promise.race([reply(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Provider RPC deadline")), RPC_TIMEOUT_MS); })]); }
      finally { clearTimeout(timer); }
    }
    try {
      const initialized = await rpc("initialize", { version: RPC_VERSION });
      expect(initialized.version).toBe(RPC_VERSION);
      const prepare = rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: scenario.wire }, request: {
        messages: [{ role: "user", content: SCHEMA_PROMPT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null }],
        functions: [], additional_functions: [], dynamic_functions: [], reasoning_effort: "max", max_output_tokens: SCHEMA_OUTPUT_LIMIT,
        tool_choice: "none", parallel_tool_calls: null, response_format: SCHEMA_FORMAT,
      } });
      if (scenario.admitted) {
        const prepared = await prepare;
        const completed = await rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(JSON.parse(completed.content)).toEqual(JSON.parse(SCHEMA_OUTPUT));
        expect(bodies).toHaveLength(1);
        expect(bodies[0].response_format).toEqual({ type: "json_schema", json_schema: { ...SCHEMA_FORMAT, strict: true } });
        expect(bodies[0].max_tokens).toBe(SCHEMA_OUTPUT_LIMIT);
        expect(bodies[0].reasoning_effort).toBe("max");
      } else {
        await expect(prepare).rejects.toThrow("Provider request failed");
        await expect(rpc("provider.stream", { handle: UNPREPARED_HANDLE, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION })).rejects.toThrow("Provider request failed");
        expect(bodies).toHaveLength(0);
      }
      await rpc("shutdown", {});
      child.stdin.end();
      expect(await child.exited).toBe(0);
      expect(await new Response(child.stderr).text()).toBe("");
    } finally {
      if (child.exitCode === null) child.kill();
      await child.exited;
      await reader.cancel();
      server.stop(true);
    }
  }, TIMEOUT_MS);

  // Token facts must survive the actual native session writer, not only RPC decoding.
  test("Go usage persists in native saved session totals", async () => {
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }], usage: { prompt_tokens: INPUT_TOKENS, completion_tokens: OUTPUT_TOKENS } }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      const output = JSON.parse(stdout);
      expect(output.output).toBe(RESULT);
      expect(output.session_id).not.toBe("");
      const saved = JSON.parse(readFileSync(join(home, SESSION_RELATIVE_DIRECTORY, output.session_id, SESSION_FILENAME), "utf8"));
      expect(saved.total_input_tokens).toBe(INPUT_TOKENS);
      expect(saved.total_output_tokens).toBe(OUTPUT_TOKENS);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native snapshot validation must precede provider projection; no local path reaches HTTP.
  test("verified image becomes an OpenAI data URL without exposing snapshot paths", async () => {
    const bodies: any[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      if (bodies.length === 1) {
        writeFileSync(join(home, IMAGE_FILENAME), CHANGED_SOURCE);
        return streamReply([{ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "read_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME) }) } }] }, finish_reason: "tool_calls" }] }]);
      }
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    home = createGoProfile(server.port);
    homes.push(home);
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const image = join(home, IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, image);
    const second = join(home, SECOND_IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, second);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", "--image", image, "--image", second, IMAGE_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(bodies).toHaveLength(2);
      for (const body of bodies) {
        const parts = body.messages.find((message: any) => Array.isArray(message.content)).content;
        expect(parts.some((part: any) => part.type === "text" && part.text.includes(IMAGE_PROMPT))).toBe(true);
        const urls = parts.filter((part: any) => part.type === "image_url").map((part: any) => part.image_url.url);
        expect(urls).toEqual(Array.from({ length: 2 }, () => "data:image/png;base64," + readFileSync(IMAGE_FIXTURE).toString("base64")));
      }
      expect(readFileSync(image, "utf8")).toBe(CHANGED_SOURCE);
      expect(JSON.stringify(bodies)).not.toContain(image);
      expect(JSON.stringify(bodies)).not.toContain(second);
      expect(JSON.stringify(bodies)).not.toContain("snapshot_path");
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // The real HTTP worker must stop its socket before a fresh explicit user request can recover.
  tuiTest.each(TTY_APIS)("real TTY %s sees early Go text, cancels HTTP and completes a fresh request", async api => {
    let requests = 0;
    let completed = 0;
    let cancelled = 0;
    const sessions: (string | null)[] = [];
    const timers = new Set<ReturnType<typeof setTimeout>>();
    const encoder = new TextEncoder();
    const server = Bun.serve({ hostname: HOST, port: 0, fetch(request) {
      requests++;
      sessions.push(request.headers.get("x-opencode-session"));
      return new Response(new ReadableStream({
        start(controller) {
          const early = api === "responses" ? [{ type: "response.output_text.delta", delta: STREAM_PREFIX }] : api === "messages" ? [messagesStart(), ...messagesText(STREAM_PREFIX).slice(0, -1)] : [{ choices: [{ index: 0, delta: { content: STREAM_PREFIX } }] }];
          controller.enqueue(encoder.encode(early.map(event => "data: " + JSON.stringify(event) + "\n\n").join("")));
          const timer = setTimeout(() => {
            timers.delete(timer);
            completed++;
            const final = api === "responses" ? [{ type: "response.output_text.delta", delta: RESULT }, responsesCompleted()] : api === "messages" ? [...messagesText(RESULT).slice(1), ...messagesTerminal()] : [{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }];
            controller.enqueue(encoder.encode(final.map(event => "data: " + JSON.stringify(event) + "\n\n").join("") + (api === "chat" ? "data: [DONE]\n\n" : "")));
            controller.close();
          }, STREAM_DELAY_MS);
          timers.add(timer);
        },
        cancel() { cancelled++; for (const timer of timers) clearTimeout(timer); timers.clear(); },
      }), { headers: { "content-type": "text/event-stream" } });
    } });
    const home = api === "responses" ? responsesProfile(server.port) : api === "messages" ? messagesProfile(server.port) : createGoProfile(server.port);
    homes.push(home);
    const stderrPath = join(home, STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { ...goEnvironment(home), FX_SKIP_ONBOARDING: "0", AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "" } });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(TUI_PROMPT);
      await session.waitForText(STREAM_PREFIX, TUI_TIMEOUT_MS);
      expect(completed).toBe(0);
      await session.sendKeys("C-c");
      await session.waitForText(CANCELLED_TEXT, TUI_TIMEOUT_MS);
      expect(session.isAlive()).toBe(true);
      await session.sendText(FOLLOWUP_PROMPT);
      const pane = await session.waitForText(RESULT, TUI_TIMEOUT_MS);
      expect(requests).toBe(2);
      expect(completed).toBe(1);
      expect(cancelled).toBeGreaterThanOrEqual(1);
      expect(sessions[0]).toBeTruthy();
      expect(sessions[1]).toBe(sessions[0]);
      expect(pane.split(RESULT)).toHaveLength(2);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      for (const timer of timers) clearTimeout(timer);
      server.stop(true);
    }
  }, TIMEOUT_MS);

  // Completed non-tool dispositions retain host length/filter handling rather than becoming RPC failures.
  test.each(CHAT_NON_TOOL_STOPS)("Chat terminal evidence preserves %s without calls", async reason => {
    let requests = 0;
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: reason }] },
        { choices: [], usage: { prompt_tokens: INPUT_TOKENS, completion_tokens: OUTPUT_TOKENS } }]);
    } });
    try {
      const home = createGoProfile(server.port);
      homes.push(home);
      const child = Bun.spawn([FX_BIN, CATALOG_COMMAND_ASK, CATALOG_JSON_FLAG, CATALOG_NO_SAVE_FLAG, TUI_PROMPT],
        { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      const response = JSON.parse(stdout);
      expect(code).toBe(reason === CHAT_LENGTH_FINISH ? CHAT_SUCCESS_EXIT : CHAT_FAILURE_EXIT);
      expect(requests).toBe(1);
      expect(response.error).not.toBe(CHAT_FAILURE);
      if (reason === CHAT_LENGTH_FINISH) {
        expect(response.output).toBe(RESULT);
        expect(stderr).toContain(CHAT_LENGTH_NOTICE);
      } else expect(response.error).toBe(CHAT_FILTER_ERROR);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // The real host must reject inconsistent terminal evidence without replay or filesystem effects.
  test.each(CHAT_TERMINAL_FAILURES)("Chat terminal evidence rejects $mode", async scenario => {
    let requests = 0;
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      if (requests > 1) return streamReply([{ choices: [{ index: 0,
        delta: { content: RESULT }, finish_reason: CATALOG_CHAT_STOP_FINISH }] }]);
      const tool_calls = [{ index: 0, id: TOOL_ID, function: { name: CHAT_WRITE_TOOL,
        arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: TOOL_CONTENT }) } }];
      const chunks: unknown[] = [];
      if (scenario.first) chunks.push({ choices: [{ index: 0,
        delta: scenario.initialCall ? { tool_calls: [{ ...tool_calls[0],
          function: { ...tool_calls[0].function, arguments: "" } }] } : {}, finish_reason: scenario.first }] });
      chunks.push({ choices: [{ index: 0, delta: {
        ...(scenario.calls ? { tool_calls } : {}), ...(scenario.content ? { content: scenario.content } : {}),
        ...(scenario.reasoning ? { reasoning_content: scenario.reasoning } : {}),
      }, finish_reason: scenario.last }] });
      return streamReply(chunks);
    } });
    try {
      home = createGoProfile(server.port);
      homes.push(home);
      const child = Bun.spawn([FX_BIN, CATALOG_COMMAND_ASK, CATALOG_JSON_FLAG, CATALOG_NO_SAVE_FLAG, TUI_PROMPT],
        { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(CHAT_FAILURE_EXIT);
      expect(JSON.parse(stdout).error).toBe(CHAT_FAILURE);
      expect(requests).toBe(1);
      expect(stdout + stderr).not.toContain(KEY);
      expect(() => readFileSync(join(home, TOOL_FILENAME))).toThrow();
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // HTTP failure, redirect and terminal-evidence loss must never trigger provider-side or host-side replay.
  test.each(NEGATIVE_CASES)("$mode remains terminal without secret disclosure or tool side effects", async ({ mode }) => {
    let requests = 0;
    let redirected = 0;
    const destination = Bun.serve({ hostname: HOST, port: 0, fetch() { redirected++; return new Response(RESULT); } });
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      if (mode === "redirect") return Response.redirect(`http://${HOST}:${destination.port}/stolen`);
      if (mode === "http-error") return new Response(ERROR_BODY + KEY, { status: 401 });
      if (mode === "lost-finish") return new Response("data: " + JSON.stringify({ choices: [{ index: 0, delta: { content: STREAM_PREFIX } }] }) + "\n\n", { headers: { "content-type": "text/event-stream" } });
      return streamReply([
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "write_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: "x".repeat(LARGE_ARGUMENT_BYTES) }) } }] } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 1, id: TOOL_ID + "-second", function: { name: "write_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: "x".repeat(LARGE_ARGUMENT_BYTES) }) } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      ]);
    } });
    try {
      home = createGoProfile(server.port);
      homes.push(home);
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(1);
      expect(JSON.parse(stdout).error).toBe("ExtensionRpcFailed");
      expect(requests).toBe(1);
      expect(redirected).toBe(0);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stdout + stderr).not.toContain(ERROR_BODY);
      expect(() => readFileSync(join(home, TOOL_FILENAME))).toThrow();
    } finally { server.stop(true); destination.stop(true); }
  }, TIMEOUT_MS);

  test.each(CASES)("local endpoint receives max, scoped headers and $name", async scenario => {
    const requests: { body: any; authorization: string | null; session: string | null; header: string | null; path: string }[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      requests.push({ body, authorization: request.headers.get("authorization"), session: request.headers.get("x-opencode-session"), header: request.headers.get("x-go-fixture"), path: new URL(request.url).pathname });
      if (requests.length === 1) return streamReply([
        { choices: [{ index: 0, delta: { reasoning_content: "", tool_calls: [{ index: 0, id: TOOL_ID, function: { name: scenario.tool, arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), ...(scenario.tool === "write_file" ? { content: LARGE_TOOL_CONTENT } : {}) }) } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 10, completion_tokens: 20 } },
      ]);
      return streamReply([
        { choices: [{ index: 0, delta: { content: RESULT }, finish_reason: CATALOG_CHAT_STOP_FINISH }] },
        { choices: [], usage: { prompt_tokens: INPUT_TOKENS, completion_tokens: OUTPUT_TOKENS } },
      ]);
    } });
    try {
      home = createGoProfile(server.port, scenario.sessionHeader);
      homes.push(home);
      if (scenario.tool === "read_file") writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", scenario.prompt], {
        cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home),
      });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout: stdout.replaceAll(KEY, "[masked]"), stderr: stderr.replaceAll(KEY, "[masked]"), requests: requests.length })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(requests).toHaveLength(2);
      expect(requests.every(request => request.path === "/v1/chat/completions" && request.authorization === "Bearer " + KEY && request.header === HEADER_VALUE)).toBe(true);
      expect(requests[0].body.model).toBe(SCHEMA_MODEL);
      expect(requests[0].body.reasoning_effort).toBe("max");
      expect(requests[0].body.tool_choice).toBe("auto");
      expect(requests[0].body.parallel_tool_calls === undefined || typeof requests[0].body.parallel_tool_calls === "boolean").toBe(true);
      const readTool = requests[0].body.tools.find((tool: any) => tool.function.name === "read_file");
      expect(readTool.function.parameters.type).toBe("object");
      expect(readTool.function.parameters.properties.path).toBeTruthy();
      expect(requests[0].session).toBeTruthy();
      expect(requests[1].session).toBe(requests[0].session);
      expect(requests[1].body.messages.some((message: any) => message.role === "assistant" && message.reasoning_content === "")).toBe(true);
      expect(requests[1].body.messages.some((message: any) => message.role === "tool")).toBe(true);
      if (scenario.tool === "read_file") expect(requests[1].body.messages.some((message: any) => message.role === "tool" && message.content.includes(TOOL_CONTENT))).toBe(true);
      else expect(readFileSync(join(home, TOOL_FILENAME), "utf8")).toBe(LARGE_TOOL_CONTENT);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);
});
