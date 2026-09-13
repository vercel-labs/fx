//! Google Interactions wire format. Keep opaque thought steps with their calls.
const std = @import("std");
const types = @import("../core/shared/types.zig");
const stream = @import("../core/agent/stream_provider.zig");
const images = @import("../core/images/image_attachments.zig");
const schemas = @import("../core/tooling/model_tool_schema.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Pair = struct { []const u8, Value };
const max_state = types.ProviderReplay.max_bytes;
const max_calls = 128;

fn str(s: []const u8) Value {
    return .{ .string = s };
}
fn object(a: Allocator, pairs: []const Pair) !Value {
    var v: Value = .{ .object = .empty };
    for (pairs) |p| try v.object.put(a, p[0], p[1]);
    return v;
}
fn array(a: Allocator, values: []const Value) !Value {
    var v: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try v.array.appendSlice(values);
    return v;
}
fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn is(v: Value, kind: []const u8) bool {
    return std.mem.eql(u8, string(v, "type") orelse "", kind);
}
fn parse(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always, .max_value_len = max_state });
}
fn textPart(a: Allocator, text: []const u8) !Value {
    return object(a, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
}
fn imagePart(a: Allocator, mime: []const u8, data: []const u8) !Value {
    return object(a, &.{ .{ "type", str("image") }, .{ "mime_type", str(mime) }, .{ "data", str(data) } });
}
fn snapshotPart(a: Allocator, image: images.VerifiedSnapshot) !Value {
    const data = try a.alloc(u8, std.base64.standard.Encoder.calcSize(image.bytes.len));
    _ = std.base64.standard.Encoder.encode(data, image.bytes);
    return imagePart(a, image.media_type, data);
}

pub fn validateModel(model: []const u8) !void {
    if (!std.mem.startsWith(u8, model, "gemini-") or model.len > 128) return error.InvalidGeminiModel;
    for (model) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return error.InvalidGeminiModel;
}

/// The caller owns the result. Temporary JSON and verified image bytes stay local.
pub fn buildRequest(alloc: Allocator, request: stream.RequestData) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const budget: images.CaptureBudget = if (request.budget) |b| .{ .deadline = b.deadline, .cancel_flag = b.cancel_flag } else .{};
    try budget.check();
    if (request.verified_images != null and (request.messages.len != 1 or request.messages[0].role != .user or request.messages[0].images.len != 0)) return error.InvalidVerifiedImagePlacement;
    var root = try object(a, &.{ .{ "model", str(request.model) }, .{ "store", .{ .bool = false } }, .{ "stream", .{ .bool = true } } });
    var instructions: std.ArrayList(u8) = .empty;
    for (request.instructions) |m| {
        if (instructions.items.len > 0) try instructions.appendSlice(a, "\n\n");
        try instructions.appendSlice(a, m.content.?);
    }
    try root.object.put(a, "system_instruction", str(instructions.items));
    var input = try array(a, &.{});
    for (request.messages) |m| {
        try budget.check();
        if (m.role == .assistant) {
            if (m.provider_replay) |replay| {
                if (replay.matches(.{ .provider = .gemini, .model = request.model })) {
                    if (replay.parts_json.len > max_state) return error.GeminiStateTooLarge;
                    const steps = try parse(a, replay.parts_json);
                    try validateReplay(steps, m.tool_calls);
                    try input.array.appendSlice(steps.array.items);
                    continue;
                }
            }
            // Imported history has no Google signatures. Preserve ordinary text.
            // Reject unsigned active calls instead of fabricating reasoning state.
            if (m.tool_calls.len != 0) return error.GeminiHistoryMissingReplay;
        }
        var parts = try array(a, &.{});
        if (m.content) |content| try parts.array.append(try textPart(a, content));
        for (m.images) |attachment| {
            var image = try images.loadVerifiedSnapshot(a, attachment, budget);
            defer image.deinit(a);
            try parts.array.append(try snapshotPart(a, image));
        }
        if (request.verified_images) |verified| for (verified) |image| {
            try parts.array.append(try snapshotPart(a, image));
        };
        if (m.role == .tool) {
            if (m.tool_result_memory) |memory| for (memory.tool_images) |image| {
                try parts.array.append(try imagePart(a, image.mime_type, image.data));
            };
            try input.array.append(try object(a, &.{
                .{ "type", str("function_result") },                                             .{ "name", str(m.tool_name orelse return error.InvalidGeminiToolResult) },
                .{ "call_id", str(m.tool_call_id orelse return error.InvalidGeminiToolResult) }, .{ "result", parts },
            }));
        } else {
            try input.array.append(try object(a, &.{ .{ "type", str(if (m.role == .assistant) "model_output" else "user_input") }, .{ "content", parts } }));
        }
    }
    try root.object.put(a, "input", input);
    var tools = try array(a, &.{});
    var names: std.StringHashMap(void) = .init(a);
    for (request.tools.advertised_names) |name| if (request.tools.advertisedFunction(name)) |tool| {
        try addStaticTool(a, &tools, &names, tool);
    };
    for (request.tools.additional_functions) |tool| try addStaticTool(a, &tools, &names, tool);
    for (request.tools.selected_dynamic) |tool| {
        if (names.contains(tool.name)) continue;
        try names.put(tool.name, {});
        try tools.array.append(try object(a, &.{ .{ "type", str("function") }, .{ "name", str(tool.name) }, .{ "description", str(tool.description) }, .{ "parameters", tool.input_schema } }));
    }
    var config = try object(a, &.{.{ "thinking_summaries", str("auto") }});
    if (tools.array.items.len > 0) {
        try root.object.put(a, "tools", tools);
        try config.object.put(a, "tool_choice", str(if (request.tool_choice == .required) "any" else request.tool_choice.label()));
    }
    if (request.provider_options.reasoning) |effort| try config.object.put(a, "thinking_level", str(effort.label()));
    if (request.max_output_tokens) |limit| try config.object.put(a, "max_output_tokens", .{ .integer = limit });
    try root.object.put(a, "generation_config", config);
    if (request.response_format) |format| {
        try root.object.put(a, "response_format", try object(a, &.{ .{ "type", str("text") }, .{ "mime_type", str("application/json") }, .{ "schema", format.schema } }));
    }
    try budget.check();
    return std.json.Stringify.valueAlloc(alloc, root, .{});
}

fn addStaticTool(a: Allocator, tools: *Value, names: *std.StringHashMap(void), tool: schemas.FunctionSchema) !void {
    if (names.contains(tool.name)) return;
    try names.put(tool.name, {});
    var out: std.Io.Writer.Allocating = .init(a);
    try schemas.writeObjectSchema(a, &out.writer, tool.input_schema);
    try tools.array.append(try object(a, &.{ .{ "type", str("function") }, .{ "name", str(tool.name) }, .{ "description", str(tool.description) }, .{ "parameters", try parse(a, out.written()) } }));
}

fn validateReplay(steps: Value, calls: []const types.ToolCall) !void {
    if (steps != .array or steps.array.items.len > 4096) return error.InvalidGeminiReplay;
    var count: usize = 0;
    for (steps.array.items) |step| {
        if (is(step, "function_call")) {
            const id = string(step, "id") orelse return error.InvalidGeminiReplay;
            const name = string(step, "name") orelse return error.InvalidGeminiReplay;
            if (count >= calls.len or !std.mem.eql(u8, id, calls[count].id) or !std.mem.eql(u8, name, calls[count].name)) return error.InvalidGeminiReplay;
            count += 1;
        } else if (!is(step, "thought") and !is(step, "model_output")) return error.InvalidGeminiReplay;
    }
    if (count != calls.len) return error.InvalidGeminiReplay;
}

pub fn projectReplay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const source = replay orelse return null;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const steps = try parse(a, source.parts_json);
    if (steps != .array) return error.InvalidGeminiReplay;
    var kept = try array(a, &.{});
    for (steps.array.items) |step| {
        var keep = if (is(step, "thought")) (reasoning or calls.len > 0) else if (is(step, "model_output")) text else false;
        if (is(step, "function_call")) for (calls) |call| {
            if (std.mem.eql(u8, string(step, "id") orelse "", call.id)) {
                keep = true;
                break;
            }
        };
        if (keep) try kept.array.append(step);
    }
    if (kept.array.items.len == 0) return null;
    return .{ .source = source.source, .parts_json = try std.json.Stringify.valueAlloc(alloc, kept, .{}) };
}

const Step = struct { value: Value, text: std.ArrayList(u8) = .empty, args: std.ArrayList(u8) = .empty, summary: Value, stopped: bool = false };
const Reducer = struct {
    arena: std.heap.ArenaAllocator,
    steps: std.ArrayList(Step) = .empty,
    content: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(types.ToolCall) = .empty,
    usage: types.Usage = .{},
    id: ?[]const u8 = null,
    finish_reason: ?types.ProviderFinishReason = null,
    complete: bool = false,

    fn apply(self: *@This(), raw: []const u8, events: stream.EventSink, capture_limit: ?usize) !void {
        const a = self.arena.allocator();
        const event = try parse(a, raw);
        const kind = string(event, "event_type") orelse return error.InvalidGeminiEvent;
        if (std.mem.eql(u8, kind, "error")) return error.GeminiStreamError;
        if (std.mem.eql(u8, kind, "interaction.created")) {
            self.id = string(field(event, "interaction") orelse return error.InvalidGeminiEvent, "id");
        } else if (std.mem.eql(u8, kind, "interaction.completed")) {
            const interaction = field(event, "interaction") orelse return error.InvalidGeminiEvent;
            const status = string(interaction, "status") orelse return error.InvalidGeminiEvent;
            for (self.steps.items) |step| if (!step.stopped) return error.GeminiStreamIncomplete;
            self.finish_reason = if (std.mem.eql(u8, status, "completed")) .stop else if (std.mem.eql(u8, status, "requires_action")) .tool_calls else if (std.mem.eql(u8, status, "incomplete")) .length else .provider_error;
            if (field(interaction, "usage")) |usage| self.usage = .{
                .input_tokens = number(usage, "total_input_tokens"),
                .output_tokens = number(usage, "total_output_tokens"),
                .cache_read_tokens = number(usage, "total_cached_tokens"),
                .reasoning_tokens = number(usage, "total_thought_tokens"),
            };
            self.complete = true;
        } else if (std.mem.startsWith(u8, kind, "step.")) {
            const index64 = number(event, "index") orelse return error.InvalidGeminiEvent;
            if (index64 > 4095) return error.GeminiStateTooLarge;
            const index: usize = @intCast(index64);
            if (std.mem.eql(u8, kind, "step.start")) {
                if (index != self.steps.items.len) return error.InvalidGeminiEvent;
                const v = field(event, "step") orelse return error.InvalidGeminiEvent;
                if (!is(v, "thought") and !is(v, "function_call") and !is(v, "model_output")) return error.UnsupportedGeminiStep;
                if (is(v, "function_call")) {
                    if (self.calls.items.len >= max_calls) return error.GeminiToolLimit;
                    const id = string(v, "id") orelse return error.InvalidGeminiEvent;
                    const name = string(v, "name") orelse return error.InvalidGeminiEvent;
                    if (id.len == 0 or id.len > 1024 or name.len == 0 or name.len > 1024) return error.InvalidGeminiEvent;
                    for (self.calls.items) |call| if (std.mem.eql(u8, call.id, id)) return error.InvalidGeminiEvent;
                    try self.calls.append(a, .{ .id = id, .name = name, .arguments_json = "{}" });
                    events.emit(.{ .tool_started = .{ .id = id, .name = name } });
                }
                var initial: Step = .{ .value = v, .summary = try array(a, &.{}) };
                if (is(v, "model_output")) {
                    if (field(v, "content")) |parts| {
                        if (parts != .array) return error.InvalidGeminiEvent;
                        for (parts.array.items) |part| {
                            if (!is(part, "text")) return error.UnsupportedGeminiStep;
                            const chunk = string(part, "text") orelse return error.InvalidGeminiEvent;
                            try initial.text.appendSlice(a, chunk);
                            events.emit(.{ .content_delta = chunk });
                            const remaining = (capture_limit orelse max_state) -| self.content.items.len;
                            try self.content.appendSlice(a, chunk[0..@min(chunk.len, remaining)]);
                        }
                    }
                }
                if (is(v, "thought")) {
                    if (field(v, "summary")) |parts| {
                        if (parts != .array) return error.InvalidGeminiEvent;
                        try initial.summary.array.appendSlice(parts.array.items);
                        for (parts.array.items) |part| if (string(part, "text")) |chunk| {
                            events.emit(.{ .reasoning_delta = chunk });
                        };
                    }
                }
                try self.steps.append(a, initial);
            } else {
                if (index >= self.steps.items.len) return error.InvalidGeminiEvent;
                const step = &self.steps.items[index];
                if (step.stopped) return error.InvalidGeminiEvent;
                if (std.mem.eql(u8, kind, "step.delta")) {
                    const delta = field(event, "delta") orelse return error.InvalidGeminiEvent;
                    if (is(delta, "text") and is(step.value, "model_output")) {
                        const chunk = string(delta, "text") orelse return error.InvalidGeminiEvent;
                        try step.text.appendSlice(a, chunk);
                        if (step.text.items.len > max_state) return error.GeminiStateTooLarge;
                        events.emit(.{ .content_delta = chunk });
                        const remaining = (capture_limit orelse max_state) -| self.content.items.len;
                        try self.content.appendSlice(a, chunk[0..@min(chunk.len, remaining)]);
                    } else if (is(delta, "arguments_delta") and is(step.value, "function_call")) {
                        const chunk = string(delta, "arguments") orelse return error.InvalidGeminiEvent;
                        try step.args.appendSlice(a, chunk);
                        if (step.args.items.len > 1024 * 1024) return error.GeminiToolArgumentsTooLarge;
                        events.emit(.{ .tool_input_delta = chunk });
                    } else if (is(delta, "thought_signature") and is(step.value, "thought")) {
                        try step.value.object.put(a, "signature", str(string(delta, "signature") orelse return error.InvalidGeminiEvent));
                    } else if (is(delta, "thought_summary") and is(step.value, "thought")) {
                        const part = field(delta, "content") orelse return error.InvalidGeminiEvent;
                        try step.summary.array.append(part);
                        if (string(part, "text")) |chunk| events.emit(.{ .reasoning_delta = chunk });
                    } else return error.UnsupportedGeminiDelta;
                } else if (std.mem.eql(u8, kind, "step.stop")) {
                    if (is(step.value, "model_output")) try step.value.object.put(a, "content", try array(a, &.{try textPart(a, step.text.items)}));
                    if (is(step.value, "thought")) {
                        const signature = string(step.value, "signature") orelse return error.GeminiMissingThoughtSignature;
                        if (signature.len == 0) return error.GeminiMissingThoughtSignature;
                        if (step.summary.array.items.len > 0) try step.value.object.put(a, "summary", step.summary);
                    }
                    if (is(step.value, "function_call")) {
                        const args = if (step.args.items.len > 0) try parse(a, step.args.items) else field(step.value, "arguments") orelse return error.InvalidGeminiEvent;
                        if (args != .object) return error.InvalidGeminiToolArguments;
                        try step.value.object.put(a, "arguments", args);
                        for (self.calls.items) |*call| if (std.mem.eql(u8, call.id, string(step.value, "id").?)) {
                            call.arguments_json = try std.json.Stringify.valueAlloc(a, args, .{});
                        };
                    }
                    step.stopped = true;
                } else return error.InvalidGeminiEvent;
            }
        }
    }

    fn finish(self: *@This(), alloc: Allocator) !types.ModelCompletion {
        if (!self.complete) return error.GeminiStreamIncomplete;
        var values = try array(self.arena.allocator(), &.{});
        for (self.steps.items) |step| try values.array.append(step.value);
        const state = try std.json.Stringify.valueAlloc(alloc, values, .{});
        errdefer alloc.free(state);
        if (state.len > max_state) return error.GeminiStateTooLarge;
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| types.freeToolCall(alloc, call);
            calls.deinit(alloc);
        }
        for (self.calls.items) |call| {
            const id = try alloc.dupe(u8, call.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, call.name);
            errdefer alloc.free(name);
            const args = try alloc.dupe(u8, call.arguments_json);
            errdefer alloc.free(args);
            try calls.append(alloc, .{ .id = id, .name = name, .arguments_json = args });
        }
        const content = try alloc.dupe(u8, self.content.items);
        errdefer alloc.free(content);
        const id = if (self.id) |v| try alloc.dupe(u8, v) else null;
        errdefer if (id) |v| alloc.free(v);
        return .{ .content = content, .tool_calls = try calls.toOwnedSlice(alloc), .generation_id = id, .provider_state_json = state, .finish_reason = self.finish_reason, .usage = self.usage };
    }
};
fn number(v: Value, key: []const u8) ?u64 {
    const f = field(v, key) orelse return null;
    return if (f == .integer and f.integer >= 0) @intCast(f.integer) else null;
}

pub fn consumeSse(alloc: Allocator, reader: *std.Io.Reader, events: stream.EventSink, cancel: *std.atomic.Value(bool), capture_limit: ?usize) !types.ModelCompletion {
    var reducer: Reducer = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    defer reducer.arena.deinit();
    var input: sse.Reader = .{ .max_event_bytes = 1024 * 1024, .max_total_bytes = 16 * 1024 * 1024 };
    defer input.deinit(alloc);
    var count: usize = 0;
    while (try input.next(alloc, reader, cancel)) |raw| {
        count += 1;
        if (count > 100_000) return error.GeminiEventLimit;
        if (std.mem.eql(u8, raw, "[DONE]")) break;
        try reducer.apply(raw, events, capture_limit);
        if (reducer.complete) break;
    }
    if (cancel.load(.seq_cst)) return error.Cancelled;
    return reducer.finish(alloc);
}

const TestSink = struct {
    fn emit(_: *anyopaque, _: stream.Event) void {}
    fn sink(self: *@This()) stream.EventSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

fn freeTestCompletion(a: Allocator, completion: types.ModelCompletion) void {
    if (completion.content) |v| a.free(v);
    if (completion.generation_id) |v| a.free(v);
    if (completion.provider_state_json) |v| a.free(v);
    for (completion.tool_calls) |call| types.freeToolCall(a, call);
    if (completion.tool_calls.len > 0) a.free(completion.tool_calls);
}

fn testToolStream(a: Allocator) !void {
    var r: Reducer = .{ .arena = std.heap.ArenaAllocator.init(a) };
    defer r.arena.deinit();
    var sink: TestSink = .{};
    const events = [_][]const u8{
        \\{"event_type":"interaction.created","interaction":{"id":"turn-1"}}
        ,
        \\{"event_type":"step.start","index":0,"step":{"type":"thought","signature":"","summary":[{"type":"text","text":"Check file."}]}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"opaque-signature"}}
        ,
        \\{"event_type":"step.stop","index":0}
        ,
        \\{"event_type":"step.start","index":1,"step":{"type":"function_call","id":"call-1","name":"read_file","arguments":{}}}
        ,
        \\{"event_type":"step.delta","index":1,"delta":{"type":"arguments_delta","arguments":"{\"path\":"}}
        ,
        \\{"event_type":"step.delta","index":1,"delta":{"type":"arguments_delta","arguments":"\"README.md\"}"}}
        ,
        \\{"event_type":"step.stop","index":1}
        ,
        \\{"event_type":"interaction.completed","interaction":{"status":"requires_action","usage":{"total_input_tokens":42,"total_output_tokens":8,"total_thought_tokens":3}}}
    };
    for (events) |event| try r.apply(event, sink.sink(), null);
    const result = try r.finish(a);
    defer freeTestCompletion(a, result);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, result.finish_reason.?);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", result.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 42), result.usage.input_tokens);
    const body = try buildRequest(a, .{ .model = "gemini-3.8-flash", .messages = &.{
        .{ .role = .assistant, .tool_calls = result.tool_calls, .provider_replay = .{ .source = .{ .provider = .gemini, .model = "gemini-3.1-pro-preview" }, .parts_json = result.provider_state_json.? } },
        .{ .role = .tool, .tool_name = "read_file", .tool_call_id = "call-1", .content = "file contents" },
    }, .tool_choice = .auto, .provider_options = .{} });
    defer a.free(body);
    try std.testing.expect(std.mem.find(u8, body, "opaque-signature") != null);
    try std.testing.expect(std.mem.find(u8, body, "function_result") != null);
    try std.testing.expect(std.mem.find(u8, body, "previous_interaction_id") == null);
}

test "Gemini streams signed calls and replays them across model changes" {
    try testToolStream(std.testing.allocator);
}

test "Gemini cleans up each failed allocation in a tool turn" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testToolStream, .{});
}

test "Gemini preserves initial text and rejects incomplete streams" {
    const a = std.testing.allocator;
    var r: Reducer = .{ .arena = std.heap.ArenaAllocator.init(a) };
    defer r.arena.deinit();
    var sink: TestSink = .{};
    try r.apply(
        \\{"event_type":"step.start","index":0,"step":{"type":"model_output","content":[{"type":"text","text":"Hello "}]}}
    , sink.sink(), null);
    try r.apply(
        \\{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"world"}}
    , sink.sink(), null);
    try std.testing.expectError(error.GeminiStreamIncomplete, r.finish(a));
    try r.apply(
        \\{"event_type":"step.stop","index":0}
    , sink.sink(), null);
    try r.apply(
        \\{"event_type":"interaction.completed","interaction":{"status":"completed"}}
    , sink.sink(), null);
    const result = try r.finish(a);
    defer freeTestCompletion(a, result);
    try std.testing.expectEqualStrings("Hello world", result.content.?);
}

test "Gemini rejects unsigned thought state and cancelled SSE" {
    const a = std.testing.allocator;
    var r: Reducer = .{ .arena = std.heap.ArenaAllocator.init(a) };
    defer r.arena.deinit();
    var sink: TestSink = .{};
    try r.apply(
        \\{"event_type":"step.start","index":0,"step":{"type":"thought","signature":""}}
    , sink.sink(), null);
    try std.testing.expectError(error.GeminiMissingThoughtSignature, r.apply(
        \\{"event_type":"step.stop","index":0}
    , sink.sink(), null));
    var reader = std.Io.Reader.fixed("data: [DONE]\n\n");
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, consumeSse(a, &reader, sink.sink(), &cancel, null));
}

test "Gemini structured output uses the Interactions response format" {
    const a = std.testing.allocator;
    var schema = try std.json.parseFromSlice(Value, a, "{\"type\":\"object\",\"properties\":{}}", .{});
    defer schema.deinit();
    const body = try buildRequest(a, .{ .model = "gemini-3.8-flash", .messages = &.{.{ .role = .user, .content = "Return JSON" }}, .tool_choice = .auto, .provider_options = .{}, .response_format = .{ .name = "answer", .description = "Answer", .schema = schema.value } });
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(Value, a, body, .{});
    defer parsed.deinit();
    const format = field(parsed.value, "response_format").?;
    try std.testing.expectEqualStrings("application/json", string(format, "mime_type").?);
    try std.testing.expectEqualStrings("text", string(format, "type").?);
    try std.testing.expect(field(format, "schema") != null);
    try std.testing.expect(field(parsed.value, "response_mime_type") == null);
}

test "Gemini rejects duplicate tool identities before admission" {
    var r: Reducer = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer r.arena.deinit();
    var sink: TestSink = .{};
    try r.apply(
        \\{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"same","name":"read_file","arguments":{}}}
    , sink.sink(), null);
    try std.testing.expectError(error.InvalidGeminiEvent, r.apply(
        \\{"event_type":"step.start","index":1,"step":{"type":"function_call","id":"same","name":"write_file","arguments":{}}}
    , sink.sink(), null));
}
