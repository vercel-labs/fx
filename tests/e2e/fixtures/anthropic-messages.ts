export const path = "/v1/messages";

export type Usage = { input: number; output: number; cached?: number; reasoning?: number };

type Event = { type: string; [field: string]: unknown };
type Block = { start: Record<string, unknown>; deltas: Array<Record<string, unknown>> };

const defaultUsage: Usage = { input: 12, output: 3 };

function sse(events: Event[]) {
  const body = events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

// `input_tokens` leaves out the cached tokens, as the recorded server reports
// them. This protocol counts thinking inside `output_tokens`, so `reasoning`
// has no field of its own.
function stream(model: string, blocks: Block[], stopReason: string, { input, output, cached = 0 }: Usage = defaultUsage) {
  const inputTokens = input - cached;
  return sse([
    { type: "message_start", message: { id: "msg-local", type: "message", role: "assistant", model, content: [], usage: { input_tokens: inputTokens, output_tokens: 0 } } },
    ...blocks.flatMap((block, index) => [
      { type: "content_block_start", index, content_block: block.start },
      ...block.deltas.map(delta => ({ type: "content_block_delta", index, delta })),
      { type: "content_block_stop", index },
    ]),
    { type: "message_delta", delta: { stop_reason: stopReason }, usage: { input_tokens: inputTokens, cache_read_input_tokens: cached, output_tokens: output } },
    { type: "message_stop" },
  ]);
}

function textBlock(text: string): Block {
  return { start: { type: "text", text: "" }, deltas: [{ type: "text_delta", text }] };
}

export function completion(model: string, text = "local reply", usage?: Usage) {
  return stream(model, [textBlock(text)], "end_turn", usage);
}

export function toolCompletion(model: string, name: string, args: unknown, callId = "call-local") {
  const block = { start: { type: "tool_use", id: callId, name, input: {} }, deltas: [{ type: "input_json_delta", partial_json: JSON.stringify(args) }] };
  return stream(model, [block], "tool_use");
}

// Not backed by a capture: the recorded server's models do not think. The
// `thinking` block and its two delta types follow the public API reference.
export function reasoningCompletion(model: string, reasoning: string, text: string) {
  const thinking = { start: { type: "thinking", thinking: "" }, deltas: [{ type: "thinking_delta", thinking: reasoning }, { type: "signature_delta", signature: "signature-local" }] };
  return stream(model, [thinking, textBlock(text)], "end_turn");
}

// Not backed by a capture: no reply was recorded with the limit reached. The
// `max_tokens` stop reason follows the public API reference.
export function lengthCut(model: string) {
  return stream(model, [], "max_tokens");
}

// Only 404 was recorded. The other names follow the public API reference.
const errorTypes: Record<number, string> = { 400: "invalid_request_error", 401: "authentication_error", 403: "permission_error", 404: "not_found_error", 413: "request_too_large", 429: "rate_limit_error", 529: "overloaded_error" };

export function errorResponse(status: number, message: string) {
  return Response.json({ type: "error", error: { type: errorTypes[status] ?? "api_error", message }, request_id: "req-local" }, { status });
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter(block => block?.type === "text").map(block => block.text).join("\n\n");
}

// A tool result travels in a user message, but it is the tool's turn, not the user's.
function isToolResult(message: any) {
  return Array.isArray(message.content) && message.content.length > 0 && message.content.every((block: any) => block?.type === "tool_result");
}

export function requestView(body: any): { model: string; system: string; userText: string; limit: number | undefined; toolNames: string[]; toolChoice: unknown } {
  const userTurns: any[] = (body.messages ?? []).filter((message: any) => message.role === "user" && !isToolResult(message));
  return {
    model: body.model,
    system: textOf(body.system),
    userText: textOf(userTurns.at(-1)?.content),
    limit: typeof body.max_tokens === "number" ? body.max_tokens : undefined,
    toolNames: (body.tools ?? []).map((tool: any) => tool.name).filter((name: unknown) => typeof name === "string"),
    toolChoice: body.tool_choice,
  };
}
