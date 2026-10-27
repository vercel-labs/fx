//! Reducer tests over recorded Messages SSE streams.
const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const model_provider = @import("../core/config/model_provider.zig");
const protocol = @import("anthropic_messages_protocol.zig");
const stream = @import("anthropic_messages_stream.zig");

const Allocator = std.mem.Allocator;

const functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "mcp.weather", .description = "Weather.", .input_schema = .{
        .properties = &.{.{ .name = "city", .json_type = .string }},
        .required = &.{"city"},
    } },
};

fn request() stream_provider.RequestData {
    return .{
        .model = "claude-test",
        .messages = &.{.{ .role = .user, .content = "weather in Paris?" }},
        .tools = .{ .advertised_names = &.{"mcp.weather"}, .advertised_functions = &functions },
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

/// Recorded from a Messages-compatible server (unknown "p" fields kept),
/// with the tool input split mid-token and a redacted thinking block added.
const tool_fixture =
    "event: message_start\n" ++
    "data: {\"p\": \"ff6e\", \"type\":\"message_start\",\"message\":{\"id\":\"msg_01\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"usage\":{\"input_tokens\":12,\"cache_creation_input_tokens\":300,\"cache_read_input_tokens\":4000,\"output_tokens\":1}}}\n\n" ++
    "event: ping\ndata: {\"type\":\"ping\"}\n\n" ++
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"The user wants\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\" weather.\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQBCkgIARABGAIi\"}}\n\n" ++
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"}}\n\n" ++
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Checking.\"}}\n\n" ++
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"mcp_weather\",\"input\":{}}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\": \\\"Pa\"}}\n\n" ++
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ris\\\"}\"}}\n\n" ++
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":3}\n\n" ++
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":59}}\n\n" ++
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

const Collector = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    /// "id:name" per tool start, then "id#index:fragment" per input delta.
    tools: std.ArrayList(u8) = .empty,
    alloc: Allocator,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |text| self.content.appendSlice(self.alloc, text) catch {},
            .reasoning_delta => |text| self.reasoning.appendSlice(self.alloc, text) catch {},
            .tool_started => |tool| self.tools.print(self.alloc, "[{s}:{s}]", .{ tool.id, tool.name }) catch {},
            .tool_input_delta => |delta| self.tools.print(self.alloc, "[{s}#{d}:{s}]", .{ delta.id, delta.index, delta.chunk }) catch {},
        }
    }
};

fn run(alloc: Allocator, fixture: []const u8, input: stream_provider.RequestData, sink: ?stream_provider.EventSink) !stream_provider.Result {
    var reader: std.Io.Reader = .fixed(fixture);
    var cancel: std.atomic.Value(bool) = .init(false);
    return stream.consume_stream(alloc, &reader, input, .{}, sink, &cancel, null);
}

test "anthropic stream reduces thinking signature redaction text tool input and cache usage" {
    const alloc = std.testing.allocator;
    var collector: Collector = .{ .alloc = alloc };
    defer collector.content.deinit(alloc);
    defer collector.reasoning.deinit(alloc);
    defer collector.tools.deinit(alloc);
    var result = try run(alloc, tool_fixture, request(), .{ .context = &collector, .emit_fn = Collector.emit });
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    // The call is announced once, then its input streams under its id.
    try std.testing.expectEqualStrings("[toolu_01:mcp.weather][toolu_01#0:{\"city\": \"Pa][toolu_01#0:ris\"}]", collector.tools.items);
    try std.testing.expectEqualStrings("Checking.", completion.content.?);
    try std.testing.expectEqualStrings("Checking.", collector.content.items);
    try std.testing.expectEqualStrings("The user wants weather.", collector.reasoning.items);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_01", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("mcp.weather", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"city\": \"Paris\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("msg_01", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 4312), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4000), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 300), completion.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 59), completion.usage.output_tokens);
    try std.testing.expectEqualStrings(
        "{\"anthropic_thinking\":[{\"type\":\"thinking\",\"thinking\":\"The user wants weather.\",\"signature\":\"EqQBCkgIARABGAIi\"},{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"}],\"_tool_call_ids\":[\"toolu_01\"]}",
        completion.provider_state_json.?,
    );

    // The envelope replays byte-exact on the next request.
    var provider = model_provider.parse("claude").?;
    provider.configured.binding = @splat(3);
    var next = request();
    next.messages = &.{
        .{ .role = .user, .content = "weather in Paris?" },
        .{ .role = .assistant, .content = completion.content, .tool_calls = completion.tool_calls, .provider_replay = .{ .source = .{ .provider = provider, .model = "claude-test" }, .parts_json = completion.provider_state_json.? } },
        .{ .role = .tool, .content = "sunny", .tool_call_id = "toolu_01", .tool_name = "mcp.weather" },
    };
    next.provider_options.reasoning = types.ReasoningEffort.literal("low");
    const body = try protocol.build_request(alloc, next, .{ .provider = &provider });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"thinking\",\"thinking\":\"The user wants weather.\",\"signature\":\"EqQBCkgIARABGAIi\"},{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"},{\"type\":\"text\",\"text\":\"Checking.\"},{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"mcp_weather\",\"input\":{\"city\": \"Paris\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}") != null);
}

test "anthropic stream message_delta usage replaces start counts" {
    const alloc = std.testing.allocator;
    const fixture =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5,\"cache_read_input_tokens\":7,\"input_tokens\":294}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var result = try run(alloc, fixture, request(), null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 301), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.cache_read_tokens);
    try std.testing.expect(completion.provider_state_json == null);
}

test "anthropic stream errors overloaded truncation and incomplete streams" {
    const alloc = std.testing.allocator;
    const start = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n";
    var overloaded = try run(alloc, start ++ "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n", request(), null);
    defer overloaded.deinit(alloc);
    try std.testing.expectEqual(stream_provider.FailureKind.unavailable, overloaded.failed.kind);
    try std.testing.expect(std.mem.find(u8, overloaded.failed.detail.?, "Overloaded") != null);
    const stop = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    try std.testing.expectError(error.OutputTruncated, run(alloc, start ++ stop, request(), null));
    try std.testing.expectError(error.IncompleteStream, run(alloc, start, request(), null));
    const open_block = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    try std.testing.expectError(error.IncompleteStream, run(alloc, start ++ open_block, request(), null));
    const tool_without_reason = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"x\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    try std.testing.expectError(error.InconsistentFinishReason, run(alloc, start ++ tool_without_reason, request(), null));
    const unsigned = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"x\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";
    var no_replay = try run(alloc, start ++ unsigned, request(), null);
    defer no_replay.deinit(alloc);
    try std.testing.expect(no_replay.completed.completion.provider_state_json == null);
}

fn allocation_probe(alloc: Allocator) !void {
    var result = try run(alloc, tool_fixture, request(), null);
    result.deinit(alloc);
}

test "anthropic stream releases memory on allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, allocation_probe, .{});
}
