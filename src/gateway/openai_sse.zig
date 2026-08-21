//! Decodes an OpenAI chat-completions SSE response stream.
//!
//! This is the wire-protocol sibling of the AI Gateway consumer in
//! `client.zig`: transports own status and headers, this module owns the
//! `choices[].delta` event grammar shared by OpenAI-compatible servers
//! (OpenAI, Ollama, vLLM, LM Studio, OpenRouter, Groq, and similar).

const std = @import("std");
const gateway_client = @import("client.zig");
const types = @import("../core/shared/types.zig");

const provider_failure_detail_max_bytes: usize = 600;

const ToolCallAccumulator = struct {
    index: u32,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    start_reported: bool = false,

    fn deinit(self: *ToolCallAccumulator, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

/// Consumes an OpenAI chat-completions SSE body from a transport-owned reader.
/// The returned completion and every populated child buffer are owned by
/// `alloc`. Cancellation returns the partial completion; the transport
/// discards it after observing the cancel flag.
pub fn consumeOpenAiSseStream(
    alloc: std.mem.Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: gateway_client.StreamCallback,
    on_tool_start: ?gateway_client.ToolStartCallback,
    on_reasoning_chunk: ?gateway_client.StreamCallback,
    on_tool_input_chunk: ?gateway_client.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);

    var accumulators: std.ArrayList(ToolCallAccumulator) = .empty;
    defer {
        for (accumulators.items) |*acc| acc.deinit(alloc);
        accumulators.deinit(alloc);
    }

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var provider_failure_detail: ?[]u8 = null;
    defer if (provider_failure_detail) |detail| alloc.free(detail);

    var event_reader = gateway_client.SseEventReader{
        .max_line_bytes = gateway_client.max_sse_event_line_bytes,
    };
    defer event_reader.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) break;
        const event = try event_reader.next(alloc, reader);
        switch (event) {
            .done, .eof, .read_failed => break,
            .ignored => continue,
            .data => |json_text| {
                var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch {
                    event_reader.releaseLine();
                    continue;
                };
                defer parsed.deinit();
                defer event_reader.releaseLine();
                if (parsed.value != .object) continue;
                const root = parsed.value.object;

                if (root.get("error")) |failure| {
                    try captureFailureDetail(alloc, &provider_failure_detail, failure);
                    if (finish_reason == null) finish_reason = .provider_error;
                }

                if (root.get("usage")) |usage_value| {
                    if (usage_value == .object) {
                        if (parseTokenCount(usage_value.object.get("prompt_tokens"))) |tokens| {
                            usage.input_tokens = tokens;
                        }
                        if (parseTokenCount(usage_value.object.get("completion_tokens"))) |tokens| {
                            usage.output_tokens = tokens;
                        }
                    }
                }

                const choices = root.get("choices") orelse continue;
                if (choices != .array or choices.array.items.len == 0) continue;
                const choice = choices.array.items[0];
                if (choice != .object) continue;

                if (choice.object.get("finish_reason")) |reason| {
                    if (reason == .string) {
                        if (types.ProviderFinishReason.parse_legacy(reason.string)) |parsed_reason| {
                            finish_reason = parsed_reason;
                        }
                    }
                }

                const delta = choice.object.get("delta") orelse continue;
                if (delta != .object) continue;

                if (jsonString(delta.object.get("content"))) |text| {
                    if (text.len > 0) {
                        on_content_chunk(callback_ctx, text);
                        try appendCapped(alloc, &content_buf, text, content_capture_limit);
                    }
                }
                // "reasoning_content" is the DeepSeek/vLLM field; "reasoning"
                // is used by OpenRouter and several local servers.
                if (jsonString(delta.object.get("reasoning_content")) orelse
                    jsonString(delta.object.get("reasoning"))) |text|
                {
                    if (text.len > 0) {
                        if (on_reasoning_chunk) |cb| cb(callback_ctx, text);
                    }
                }

                if (delta.object.get("tool_calls")) |tool_calls| {
                    if (tool_calls == .array) {
                        for (tool_calls.array.items) |fragment| {
                            try accumulateToolCallFragment(
                                alloc,
                                &accumulators,
                                fragment,
                                callback_ctx,
                                on_tool_start,
                                on_tool_input_chunk,
                            );
                        }
                    }
                }
            },
        }
    }

    var completion = types.GatewayCompletion{
        .finish_reason = finish_reason,
        .usage = usage,
    };
    if (content_buf.items.len > 0) {
        completion.content = try alloc.dupe(u8, content_buf.items);
    }
    errdefer if (completion.content) |content| alloc.free(@constCast(content));
    if (provider_failure_detail) |detail| {
        completion.provider_failure_detail = try alloc.dupe(u8, detail);
    }
    errdefer if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    completion.tool_calls = try materializeToolCalls(alloc, accumulators.items);
    return completion;
}

fn accumulateToolCallFragment(
    alloc: std.mem.Allocator,
    accumulators: *std.ArrayList(ToolCallAccumulator),
    fragment: std.json.Value,
    callback_ctx: *anyopaque,
    on_tool_start: ?gateway_client.ToolStartCallback,
    on_tool_input_chunk: ?gateway_client.StreamCallback,
) !void {
    if (fragment != .object) return;
    const index: u32 = if (fragment.object.get("index")) |value| switch (value) {
        .integer => |raw| if (raw >= 0 and raw <= std.math.maxInt(u32)) @intCast(raw) else return,
        else => return,
    } else 0;

    const acc = find: {
        for (accumulators.items) |*candidate| {
            if (candidate.index == index) break :find candidate;
        }
        try accumulators.append(alloc, .{ .index = index });
        break :find &accumulators.items[accumulators.items.len - 1];
    };

    if (jsonString(fragment.object.get("id"))) |id| {
        try acc.id.appendSlice(alloc, id);
    }
    if (fragment.object.get("function")) |function| {
        if (function == .object) {
            if (jsonString(function.object.get("name"))) |name| {
                try acc.name.appendSlice(alloc, name);
            }
            if (jsonString(function.object.get("arguments"))) |arguments| {
                if (arguments.len > 0) {
                    try acc.arguments.appendSlice(alloc, arguments);
                    if (on_tool_input_chunk) |cb| cb(callback_ctx, arguments);
                }
            }
        }
    }
    if (!acc.start_reported and acc.id.items.len > 0 and acc.name.items.len > 0) {
        acc.start_reported = true;
        if (on_tool_start) |cb| cb(callback_ctx, acc.id.items, acc.name.items, null);
    }
}

fn materializeToolCalls(
    alloc: std.mem.Allocator,
    accumulators: []const ToolCallAccumulator,
) ![]const types.ToolCall {
    if (accumulators.len == 0) return &.{};

    const calls = try alloc.alloc(types.ToolCall, accumulators.len);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
        }
        alloc.free(calls);
    }

    for (accumulators, 0..) |acc, i| {
        const id = try alloc.dupe(u8, acc.id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, acc.name.items);
        errdefer alloc.free(name);
        const raw_arguments: []const u8 = if (acc.arguments.items.len > 0) acc.arguments.items else "{}";
        const arguments = try alloc.dupe(u8, raw_arguments);
        errdefer alloc.free(arguments);

        calls[i] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments,
            .argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, arguments),
        };
        initialized += 1;
    }

    return calls;
}

fn captureFailureDetail(
    alloc: std.mem.Allocator,
    current: *?[]u8,
    failure: std.json.Value,
) !void {
    if (current.* != null) return;
    const text = switch (failure) {
        .string => |value| value,
        .object => |obj| jsonString(obj.get("message")) orelse return,
        else => return,
    };
    if (text.len == 0) return;
    const clipped = text[0..@min(text.len, provider_failure_detail_max_bytes)];
    current.* = try alloc.dupe(u8, clipped);
}

fn appendCapped(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
    limit: ?usize,
) !void {
    const max = limit orelse {
        try buf.appendSlice(alloc, text);
        return;
    };
    if (buf.items.len >= max) return;
    const remaining = max - buf.items.len;
    try buf.appendSlice(alloc, text[0..@min(text.len, remaining)]);
}

fn parseTokenCount(value: ?std.json.Value) ?u64 {
    const raw = value orelse return null;
    return switch (raw) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const raw = value orelse return null;
    return switch (raw) {
        .string => |text| text,
        else => null,
    };
}

const TestCapture = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    tool_starts: usize = 0,
    failed: bool = false,

    fn deinit(self: *TestCapture) void {
        self.content.deinit(std.testing.allocator);
        self.reasoning.deinit(std.testing.allocator);
        self.tool_input.deinit(std.testing.allocator);
    }

    fn onContent(raw: *anyopaque, chunk: []const u8) void {
        const self: *TestCapture = @ptrCast(@alignCast(raw));
        self.content.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn onReasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *TestCapture = @ptrCast(@alignCast(raw));
        self.reasoning.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn onToolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *TestCapture = @ptrCast(@alignCast(raw));
        self.tool_input.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn onToolStart(raw: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
        const self: *TestCapture = @ptrCast(@alignCast(raw));
        self.tool_starts += 1;
    }
};

fn consumeTestStream(sse_body: []const u8, capture: *TestCapture) !types.GatewayCompletion {
    var reader: std.Io.Reader = .fixed(sse_body);
    var cancelled = std.atomic.Value(bool).init(false);
    return consumeOpenAiSseStream(
        std.testing.allocator,
        &reader,
        capture,
        TestCapture.onContent,
        TestCapture.onToolStart,
        TestCapture.onReasoning,
        TestCapture.onToolInput,
        &cancelled,
        null,
    );
}

fn freeTestCompletion(completion: *types.GatewayCompletion) void {
    const alloc = std.testing.allocator;
    if (completion.content) |content| alloc.free(@constCast(content));
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
}

test "openai sse stream accumulates content, reasoning, and usage" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\",\"reasoning_content\":\"think\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":7}}\n\n" ++
        "data: [DONE]\n";

    var capture = TestCapture{};
    defer capture.deinit();
    var completion = try consumeTestStream(body, &capture);
    defer freeTestCompletion(&completion);

    try std.testing.expect(!capture.failed);
    try std.testing.expectEqualStrings("Hello", capture.content.items);
    try std.testing.expectEqualStrings("think", capture.reasoning.items);
    try std.testing.expectEqualStrings("Hello", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.output_tokens);
}

test "openai sse stream assembles index-keyed tool call fragments" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"a.txt\\\"}\"}},{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"list_dir\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n";

    var capture = TestCapture{};
    defer capture.deinit();
    var completion = try consumeTestStream(body, &capture);
    defer freeTestCompletion(&completion);

    try std.testing.expect(!capture.failed);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_starts);
    try std.testing.expectEqual(@as(usize, 2), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, completion.tool_calls[0].argument_integrity);
    try std.testing.expectEqualStrings("call_2", completion.tool_calls[1].id);
    try std.testing.expectEqualStrings("list_dir", completion.tool_calls[1].name);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "openai sse stream captures provider errors and malformed arguments" {
    const body =
        "data: {\"error\":{\"message\":\"model overloaded\",\"type\":\"server_error\"}}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_x\",\"function\":{\"name\":\"run\",\"arguments\":\"{not json\"}}]}}]}\n\n" ++
        "data: [DONE]\n";

    var capture = TestCapture{};
    defer capture.deinit();
    var completion = try consumeTestStream(body, &capture);
    defer freeTestCompletion(&completion);

    try std.testing.expectEqualStrings("model overloaded", completion.provider_failure_detail.?);
    try std.testing.expectEqual(types.ProviderFinishReason.provider_error, completion.finish_reason.?);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, completion.tool_calls[0].argument_integrity);
}
