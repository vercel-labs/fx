export const path = "/v1/responses";

export type Usage = { input: number; output: number; cached?: number; reasoning?: number };

type Event = { type: string; [field: string]: unknown };
type Item = { id: string; type: string; [field: string]: unknown };
type Output = { item: Item; events: Event[] };

const defaultUsage: Usage = { input: 12, output: 3 };
const createdAt = 1794248476;

// The stream ends with its last event: this protocol has no `[DONE]` line.
function sse(events: Event[]) {
  const body = events.map((event, index) => `event: ${event.type}\ndata: ${JSON.stringify({ ...event, sequence_number: index })}\n\n`).join("");
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

function usageOf({ input, output, cached = 0, reasoning = 0 }: Usage) {
  return { input_tokens: input, input_tokens_details: { cached_tokens: cached }, output_tokens: output, output_tokens_details: { reasoning_tokens: reasoning }, total_tokens: input + output };
}

function response(model: string, status: string, fields: Record<string, unknown> = {}) {
  return { id: "resp-local", object: "response", created_at: createdAt, completed_at: null, status, error: null, incomplete_details: null, model, output: [], usage: null, ...fields };
}

function opening(model: string): Event[] {
  return ["response.created", "response.in_progress"].map(type => ({ type, response: response(model, "in_progress") }));
}

function stream(model: string, outputs: Output[], usage = defaultUsage) {
  const done = response(model, "completed", { completed_at: createdAt, output: outputs.map(output => output.item), usage: usageOf(usage) });
  return sse([...opening(model), ...outputs.flatMap(output => output.events), { type: "response.completed", response: done }]);
}

function message(text: string, outputIndex: number): Output {
  const id = "msg-local";
  const part = { type: "output_text", text, annotations: [] };
  const item = { id, type: "message", role: "assistant", status: "completed", content: [part] };
  const at = { item_id: id, output_index: outputIndex, content_index: 0 };
  return {
    item,
    events: [
      { type: "response.output_item.added", output_index: outputIndex, item: { ...item, status: "in_progress", content: [] } },
      { type: "response.content_part.added", ...at, part: { ...part, text: "" } },
      { type: "response.output_text.delta", ...at, delta: text },
      { type: "response.output_text.done", ...at, text },
      { type: "response.content_part.done", ...at, part },
      { type: "response.output_item.done", output_index: outputIndex, item },
    ],
  };
}

function functionCall(name: string, args: unknown, callId: string, outputIndex: number): Output {
  const id = "fc-local";
  const json = JSON.stringify(args);
  const item = { id, type: "function_call", status: "completed", call_id: callId, name, arguments: json };
  const at = { item_id: id, output_index: outputIndex };
  return {
    item,
    events: [
      { type: "response.output_item.added", output_index: outputIndex, item: { ...item, status: "in_progress", arguments: "" } },
      { type: "response.function_call_arguments.delta", ...at, delta: json },
      { type: "response.function_call_arguments.done", ...at, arguments: json },
      { type: "response.output_item.done", output_index: outputIndex, item },
    ],
  };
}

function reasoning(text: string, outputIndex: number): Output {
  const id = "rs-local";
  const part = { type: "summary_text", text };
  const item = { id, type: "reasoning", summary: [part], encrypted_content: "encrypted-local" };
  const at = { item_id: id, output_index: outputIndex, summary_index: 0 };
  return {
    item,
    events: [
      { type: "response.output_item.added", output_index: outputIndex, item: { id, type: "reasoning", summary: [] } },
      { type: "response.reasoning_summary_part.added", ...at, part: { ...part, text: "" } },
      { type: "response.reasoning_summary_text.delta", ...at, delta: text },
      { type: "response.reasoning_summary_text.done", ...at, text },
      { type: "response.reasoning_summary_part.done", ...at, part },
      { type: "response.output_item.done", output_index: outputIndex, item },
    ],
  };
}

export function completion(model: string, text = "local reply", usage?: Usage) {
  return stream(model, [message(text, 0)], usage);
}

export function toolCompletion(model: string, name: string, args: unknown, callId = "call-local") {
  return stream(model, [functionCall(name, args, callId, 0)]);
}

// Not backed by a capture: the recorded server's models do not reason. The
// reasoning item and its summary events follow the public API reference.
export function reasoningCompletion(model: string, reasoningText: string, text: string) {
  return stream(model, [reasoning(reasoningText, 0), message(text, 1)]);
}

// Not backed by a capture: no reply was recorded with the limit reached. The
// `response.incomplete` event follows the public API reference.
export function lengthCut(model: string) {
  const cut = response(model, "incomplete", { incomplete_details: { reason: "max_output_tokens" }, usage: usageOf(defaultUsage) });
  return sse([...opening(model), { type: "response.incomplete", response: cut }]);
}

// The recorded server sends this body on the Chat Completions path too, where a
// 400 was also recorded. `api_error` for any other status is not backed by a capture.
export function errorResponse(status: number, message: string) {
  const type = status === 400 ? "invalid_request_error" : status === 404 ? "not_found_error" : "api_error";
  return Response.json({ error: { message, type, param: null, code: null } }, { status });
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter(part => typeof part?.text === "string").map(part => part.text).join("\n\n");
}

export function requestView(body: any): { model: string; system: string; userText: string; limit: number | undefined; toolNames: string[]; toolChoice: unknown } {
  const messages: any[] = typeof body.input === "string" ? [{ role: "user", content: body.input }] : (body.input ?? []).filter((item: any) => item.role);
  const said = (...roles: string[]) => messages.filter(item => roles.includes(item.role)).map(item => textOf(item.content));
  return {
    model: body.model,
    system: [textOf(body.instructions), ...said("system", "developer")].filter(Boolean).join("\n\n"),
    userText: said("user").at(-1) ?? "",
    limit: typeof body.max_output_tokens === "number" ? body.max_output_tokens : undefined,
    toolNames: (body.tools ?? []).map((tool: any) => tool.name).filter((name: unknown) => typeof name === "string"),
    toolChoice: body.tool_choice,
  };
}
