// Proves the fake Responses and Messages servers in tests/e2e/fixtures/ against
// replies recorded from a real server (tests/e2e/fixtures/custom-endpoint-captures/),
// so a test of a custom model connection fails for what fx does and never for
// a shape the fake made up. Starts no fx process and needs no built binary.
import { describe, test } from "bun:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as messages from "../../../e2e/fixtures/anthropic-messages";
import * as responses from "../../../e2e/fixtures/responses";

const captures = join(import.meta.dirname, "..", "..", "..", "e2e", "fixtures", "custom-endpoint-captures");
const capture = (name: string) => readFileSync(join(captures, name), "utf8");

type Sse = { event: string; data: any };
type Shape = Map<string, Set<string>>;

// A payload that is not a JSON object, such as `[DONE]`, stays a string, so it
// fails as an event the capture does not have.
function parseSse(text: string): Sse[] {
  return text.split("\n\n").filter(block => block.trim() !== "").map(block => {
    const lines = block.split("\n");
    const field = (name: string) => lines.filter(line => line.startsWith(`${name}: `)).map(line => line.slice(name.length + 2)).join("\n");
    const data = field("data");
    return { event: field("event"), data: data.startsWith("{") ? JSON.parse(data) : data };
  });
}

function jsonType(value: unknown) {
  return value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
}

// Every key path in a value with the JSON types seen there. `[]` stands for any array element.
function keyPaths(value: unknown, path = "", into: Shape = new Map()): Shape {
  if (path !== "") into.set(path, (into.get(path) ?? new Set()).add(jsonType(value)));
  if (Array.isArray(value)) for (const element of value) keyPaths(element, `${path}[]`, into);
  else if (value !== null && typeof value === "object") for (const [key, child] of Object.entries(value)) keyPaths(child, path === "" ? key : `${path}.${key}`, into);
  return into;
}

function shapesByEvent(events: Sse[]) {
  const shapes = new Map<string, Shape>();
  for (const { event, data } of events) shapes.set(event, keyPaths(data, "", shapes.get(event)));
  return shapes;
}

const listed = (shape: Shape) => [...shape].map(([path, types]) => `${path}: ${[...types].sort().join("|")}`).sort();
const names = (events: Sse[]) => events.map(event => event.event);
const collapsed = (list: string[]) => list.filter((name, index) => name !== list[index - 1]);
const named = (events: Sse[], name: string) => events.filter(event => event.event === name).map(event => event.data);

async function sent(reply: Response) {
  assert.equal(reply.status, 200);
  assert.equal(reply.headers.get("content-type"), "text/event-stream");
  return parseSse(await reply.text());
}

function assertFaithful(fake: Sse[], recorded: Sse[], required: string[]) {
  for (const { event, data } of [...fake, ...recorded]) assert.equal(data.type, event, "the event line names the payload's type");
  const recordedShapes = shapesByEvent(recorded);
  for (const [event, shape] of shapesByEvent(fake)) {
    const real = recordedShapes.get(event);
    assert.ok(real, `the fake sends ${event}, which the capture does not have`);
    for (const [path, types] of shape) {
      for (const type of types) assert.ok(real.get(path)?.has(type), `${event}: the fake sends ${path} as ${type}, the capture has ${[...(real.get(path) ?? ["no such key"])].join(" or ")}`);
    }
    for (const path of required) assert.ok(!real.has(path) || shape.has(path), `${event}: the fake leaves out ${path}`);
  }
}

const tool = { name: "read_file", args: { path: "/Users/example/note.txt" } };
const shared = { model: "local-model", system: "You are terse.\n\nAnswer in English.", userText: "second question", limit: 256, toolNames: ["read_file"] };
const bare = { model: "local-model", system: "", userText: "hello", limit: undefined, toolNames: [], toolChoice: undefined };

const protocols = [
  {
    name: "Responses", prefix: "responses", fake: responses, path: "/v1/responses",
    required: ["response.id", "response.status", "response.output", "response.usage.input_tokens", "response.usage.output_tokens", "item.type", "item.id", "delta"],
    request: {
      model: "local-model", stream: true, max_output_tokens: 256, tool_choice: "auto", instructions: "You are terse.",
      tools: [{ type: "function", name: "read_file", description: "Read a file", parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } }],
      input: [
        { role: "developer", content: [{ type: "input_text", text: "Answer in English." }] },
        { role: "user", content: "first question" },
        { role: "assistant", content: [{ type: "output_text", text: "first answer" }] },
        { role: "user", content: [{ type: "input_text", text: "second question" }] },
        { type: "function_call", call_id: "call-1", name: "read_file", arguments: "{\"path\":\"/Users/example/note.txt\"}" },
        { type: "function_call_output", call_id: "call-1", output: "file text" },
      ],
    },
    view: { ...shared, toolChoice: "auto" },
    bareRequest: { model: "local-model", input: "hello" },
  },
  {
    name: "Messages", prefix: "messages", fake: messages, path: "/v1/messages",
    required: ["message.id", "message.usage.input_tokens", "content_block.type", "delta.type", "delta.stop_reason", "usage.output_tokens"],
    request: {
      model: "local-model", stream: true, max_tokens: 256, tool_choice: { type: "auto" },
      system: [{ type: "text", text: "You are terse." }, { type: "text", text: "Answer in English.", cache_control: { type: "ephemeral" } }],
      tools: [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } }],
      messages: [
        { role: "user", content: "first question" },
        { role: "assistant", content: [{ type: "text", text: "first answer" }] },
        { role: "user", content: [{ type: "text", text: "second question" }] },
        { role: "assistant", content: [{ type: "tool_use", id: "call-1", name: "read_file", input: { path: "/Users/example/note.txt" } }] },
        { role: "user", content: [{ type: "tool_result", tool_use_id: "call-1", content: "file text" }] },
      ],
    },
    view: { ...shared, toolChoice: { type: "auto" } },
    bareRequest: { model: "local-model", messages: [{ role: "user", content: "hello" }] },
  },
];

for (const { name, prefix, fake, path, required, request, view, bareRequest } of protocols) {
  describe(`${name} fake`, () => {
    test("serves the protocol's path", () => {
      assert.equal(fake.path, path);
    });

    test("completion sends the recorded text reply's events and fields", async () => {
      const recorded = parseSse(capture(`${prefix}-text.sse`));
      const events = await sent(fake.completion("local-model", "ok"));
      assert.deepEqual(collapsed(names(events)), collapsed(names(recorded)));
      assertFaithful(events, recorded, required);
    });

    test("toolCompletion sends the recorded tool call's events and fields", async () => {
      const recorded = parseSse(capture(`${prefix}-tool-call.sse`));
      const events = await sent(fake.toolCompletion("local-model", tool.name, tool.args));
      assert.deepEqual(names(events), names(recorded));
      assertFaithful(events, recorded, required);
    });

    test("errorResponse sends the recorded unknown-model body", async () => {
      const recorded = JSON.parse(capture(`${prefix}-unknown-model.json`));
      const reply = fake.errorResponse(404, recorded.error.message);
      const body = await reply.json();
      assert.equal(reply.status, 404);
      assert.deepEqual(listed(keyPaths(body)), listed(keyPaths(recorded)));
      assert.deepEqual(body.error, recorded.error);
    });

    test("requestView reads a request into the neutral shape", () => {
      assert.deepEqual(fake.requestView(request), view);
      assert.deepEqual(fake.requestView(bareRequest), bare);
    });
  });
}

describe("Responses fake", () => {
  const last = (events: Sse[]) => events[events.length - 1].data;

  test("numbers its events from zero, as both captures do", async () => {
    const streams = [
      parseSse(capture("responses-text.sse")), parseSse(capture("responses-tool-call.sse")),
      await sent(responses.completion("local-model")), await sent(responses.toolCompletion("local-model", tool.name, tool.args)),
      await sent(responses.reasoningCompletion("local-model", "thinking", "ok")), await sent(responses.lengthCut("local-model")),
    ];
    for (const events of streams) assert.deepEqual(events.map(event => event.data.sequence_number), events.map((_, index) => index));
  });

  test("carries the text, the call, and the counts it was given", async () => {
    const text = await sent(responses.completion("local-model", "hello there", { input: 40, output: 5, cached: 30, reasoning: 2 }));
    assert.deepEqual(named(text, "response.output_text.delta").map(data => data.delta), ["hello there"]);
    assert.equal(last(text).response.output[0].content[0].text, "hello there");
    assert.deepEqual(last(text).response.usage, { input_tokens: 40, input_tokens_details: { cached_tokens: 30 }, output_tokens: 5, output_tokens_details: { reasoning_tokens: 2 }, total_tokens: 45 });
    assert.deepEqual(last(await sent(responses.completion("local-model"))).response.usage, { input_tokens: 12, input_tokens_details: { cached_tokens: 0 }, output_tokens: 3, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 15 });

    const call = last(await sent(responses.toolCompletion("local-model", tool.name, tool.args, "call-7"))).response.output[0];
    assert.deepEqual({ ...call, arguments: JSON.parse(call.arguments) }, { id: call.id, type: "function_call", status: "completed", call_id: "call-7", name: tool.name, arguments: tool.args });
  });

  // No capture backs these two replies. This pins the shape the builders were asked for.
  test("reasoningCompletion and lengthCut send the shapes that no capture backs", async () => {
    const reasoned = await sent(responses.reasoningCompletion("local-model", "weigh it", "ok"));
    assert.deepEqual(collapsed(names(reasoned)), [
      "response.created", "response.in_progress",
      "response.output_item.added", "response.reasoning_summary_part.added", "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done", "response.reasoning_summary_part.done", "response.output_item.done",
      "response.output_item.added", "response.content_part.added", "response.output_text.delta", "response.output_text.done", "response.content_part.done", "response.output_item.done",
      "response.completed",
    ]);
    assert.deepEqual(named(reasoned, "response.reasoning_summary_text.delta").map(data => data.delta), ["weigh it"]);
    assert.deepEqual(named(reasoned, "response.output_item.done").map(data => [data.output_index, data.item.type, typeof data.item.encrypted_content]), [[0, "reasoning", "string"], [1, "message", "undefined"]]);
    assert.deepEqual(last(reasoned).response.output.map((item: any) => item.type), ["reasoning", "message"]);

    const cut = await sent(responses.lengthCut("local-model"));
    assert.deepEqual(names(cut), ["response.created", "response.in_progress", "response.incomplete"]);
    assert.equal(last(cut).response.status, "incomplete");
    assert.deepEqual(last(cut).response.incomplete_details, { reason: "max_output_tokens" });
    assert.deepEqual(last(cut).response.output, []);
  });
});

describe("Messages fake", () => {
  const usages = (events: Sse[]) => [named(events, "message_start")[0].message.usage, named(events, "message_delta")[0].usage];

  test("carries the text, the call, and the counts it was given", async () => {
    const text = await sent(messages.completion("local-model", "hello there", { input: 40, output: 5, cached: 30 }));
    assert.deepEqual(named(text, "content_block_delta").map(data => data.delta.text), ["hello there"]);
    assert.deepEqual(usages(text), [{ input_tokens: 10, output_tokens: 0 }, { input_tokens: 10, cache_read_input_tokens: 30, output_tokens: 5 }]);
    assert.deepEqual(usages(await sent(messages.completion("local-model"))), [{ input_tokens: 12, output_tokens: 0 }, { input_tokens: 12, cache_read_input_tokens: 0, output_tokens: 3 }]);

    const call = await sent(messages.toolCompletion("local-model", tool.name, tool.args, "call-7"));
    assert.deepEqual(named(call, "content_block_start")[0].content_block, { type: "tool_use", id: "call-7", name: tool.name, input: {} });
    assert.deepEqual(JSON.parse(named(call, "content_block_delta").map(data => data.delta.partial_json).join("")), tool.args);
  });

  // No capture backs these two replies. This pins the shape the builders were asked for.
  test("reasoningCompletion and lengthCut send the shapes that no capture backs", async () => {
    const reasoned = await sent(messages.reasoningCompletion("local-model", "weigh it", "ok"));
    assert.deepEqual(named(reasoned, "content_block_start").map(data => [data.index, data.content_block.type]), [[0, "thinking"], [1, "text"]]);
    assert.deepEqual(named(reasoned, "content_block_delta").map(data => [data.index, data.delta]), [
      [0, { type: "thinking_delta", thinking: "weigh it" }], [0, { type: "signature_delta", signature: "signature-local" }], [1, { type: "text_delta", text: "ok" }],
    ]);
    assert.equal(named(reasoned, "message_delta")[0].delta.stop_reason, "end_turn");

    const cut = await sent(messages.lengthCut("local-model"));
    assert.deepEqual(names(cut), ["message_start", "message_delta", "message_stop"]);
    assert.equal(named(cut, "message_delta")[0].delta.stop_reason, "max_tokens");
  });
});
