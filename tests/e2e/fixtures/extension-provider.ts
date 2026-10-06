// A deterministic local executable proves host authority and lifetime boundaries without HTTP.
import { createInterface } from "node:readline";
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const LOG_FILENAME = "rpc-log.jsonl";
const RESULT_TEXT = "extension-rpc-ok";
const STREAM_PREFIX = "extension-first-chunk";
const STREAM_SUFFIX = "-completed";
const STREAM_MODE_FILENAME = "stream-events";
const FINISHED_FILENAME = "stream-finished";
const FOREIGN_MODE_FILENAME = "foreign-handle";
const FOREIGN_HANDLE = "foreign-prepared-handle";
const FOREIGN_TEXT = "foreign-event-must-not-render";
const LARGE_EVENT_FILENAME = "large-event";
const MISMATCH_FILENAME = "content-mismatch";
const LARGE_DELTA_BYTES = 64 * 1024 + 1;
const MISMATCH_TEXT = "streamed-content-does-not-match";
const TOOL_MODE_FILENAME = "tool-roundtrip";
const TOOL_FILENAME = "fixture-tool-data.txt";
const TOOL_CONTENT = "fixture-tool-read-marker";
const TOOL_ID = "fixture-tool-call";
const TOOL_NAME = "read_file";
const TOOL_LABEL = "Reading fixture";
const TOOL_RESULT_TEXT = "extension-tool-loop-ok";
const TOOL_FINISH_REASON = "tool_calls";
const REPLAY_STATE_MARKER = "fixture-reasoning-replay";
const REPLAY_STATE = JSON.stringify({ marker: REPLAY_STATE_MARKER, reasoning_content: "" });
const STREAM_DELAY_MS = 2_000;
const PROTOCOL_VERSION = 1;
const JSONRPC_VERSION = "2.0";
const PREPARED_HANDLE = "prepared-fixture";
const FINISH_REASON = "stop";
const MISSING_FINISH_FILENAME = "missing-finish";
const DROP_STREAM_FILENAME = "drop-stream";
const FAILURE_EXIT_CODE = 1;
const SUCCESS_EXIT_CODE = 0;
const CREDENTIAL_SLOT = "FX_EXTENSION_TEST_KEY";
const methods = { initialize: "initialize", prepare: "provider.prepare", stream: "provider.stream", cancel: "provider.cancel", shutdown: "shutdown", event: "extension.event" };
const events = { content: "content_delta", reasoning: "reasoning_delta", tool_started: "tool_started", tool_input: "tool_input_delta" };
const lines = createInterface({ input: process.stdin });
const active = new Map<string, ReturnType<typeof setTimeout>>();
let tool_requested = false;
let tool_replayed = false;
let reasoning_replayed = false;

// The pending request stays readable so cancellation never waits for the simulated provider.
function reply(id: number, result: unknown) {
  process.stdout.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, id, result }) + "\n");
}

// Notifications carry both identities to expose accidental cross-request event delivery.
function notify(request: any, type: string, fields: Record<string, unknown>, handle = request.params.handle) {
  process.stdout.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, method: methods.event,
    params: { request_id: request.id, handle, type, ...fields } }) + "\n");
}

for await (const line of lines) {
  const request = JSON.parse(line);
  appendFileSync(LOG_FILENAME, JSON.stringify({ method: request.method, pid: process.pid,
    credential: Boolean(request.params.credential), ambientKey: Boolean(process.env[CREDENTIAL_SLOT]) }) + "\n");
  let result: unknown;
  switch (request.method) {
    case methods.initialize: result = { version: PROTOCOL_VERSION }; break;
    case methods.prepare:
      if (tool_requested) {
        const messages = request.params.request.messages;
        tool_replayed = messages.some((message: any) => message.role === "tool" && message.content?.includes(TOOL_CONTENT));
        reasoning_replayed = messages.some((message: any) => {
          if (!message.provider_state_json) return false;
          const state = JSON.parse(message.provider_state_json);
          return state.marker === REPLAY_STATE_MARKER && state.reasoning_content === "";
        });
      }
      result = { handle: PREPARED_HANDLE };
      break;
    case methods.stream:
      if (existsSync(TOOL_MODE_FILENAME)) {
        if (!tool_requested) {
          tool_requested = true;
          const arguments_json = JSON.stringify({ path: join(process.cwd(), "..", "..", TOOL_FILENAME) });
          notify(request, events.reasoning, { delta: "local reasoning" });
          notify(request, events.tool_started, { id: TOOL_ID, name: TOOL_NAME, label: TOOL_LABEL });
          notify(request, events.tool_input, { id: TOOL_ID, delta: arguments_json });
          result = { tool_calls: [{ id: TOOL_ID, name: TOOL_NAME, arguments_json }], provider_state_json: REPLAY_STATE, finish_reason: TOOL_FINISH_REASON };
        } else {
          if (!tool_replayed || !reasoning_replayed) throw new Error("missing fixture tool or reasoning replay");
          result = { content: TOOL_RESULT_TEXT, finish_reason: FINISH_REASON };
        }
        break;
      }
      if (existsSync(DROP_STREAM_FILENAME)) process.exit(FAILURE_EXIT_CODE);
      if (existsSync(FOREIGN_MODE_FILENAME)) notify(request, events.content, { delta: FOREIGN_TEXT }, FOREIGN_HANDLE);
      if (existsSync(LARGE_EVENT_FILENAME)) notify(request, events.content, { delta: "x".repeat(LARGE_DELTA_BYTES) });
      if (existsSync(MISMATCH_FILENAME)) notify(request, events.content, { delta: MISMATCH_TEXT });
      if (existsSync(STREAM_MODE_FILENAME)) {
        notify(request, events.reasoning, { delta: "local reasoning" });
        notify(request, events.content, { delta: STREAM_PREFIX });
        active.set(request.params.handle, setTimeout(() => {
          notify(request, events.content, { delta: STREAM_SUFFIX });
          writeFileSync(FINISHED_FILENAME, "");
          reply(request.id, { content: STREAM_PREFIX + STREAM_SUFFIX, finish_reason: FINISH_REASON });
          active.delete(request.params.handle);
        }, STREAM_DELAY_MS));
        continue;
      }
      result = { content: RESULT_TEXT, ...(existsSync(MISSING_FINISH_FILENAME) ? {} : { finish_reason: FINISH_REASON }) };
      break;
    case methods.cancel:
      clearTimeout(active.get(request.params.handle));
      active.delete(request.params.handle);
      result = {};
      break;
    case methods.shutdown:
      for (const timer of active.values()) clearTimeout(timer);
      result = {};
      break;
    default: throw new Error("unexpected fixture RPC method");
  }
  reply(request.id, result);
  if (request.method === methods.shutdown) process.exit(SUCCESS_EXIT_CODE);
}
