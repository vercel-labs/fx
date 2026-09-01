const std = @import("std");
const openai_transport = @import("../core/gateway/openai_transport.zig");
const types = @import("../core/shared/types.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");

const Allocator = std.mem.Allocator;
const max_sse_event_line_bytes: usize = 4 * 1024 * 1024;

/// Consumes an OpenAI chat-completions SSE stream and reduces chunk events
/// into a model completion, emitting deltas through the provider event sink.
pub fn consumeOpenAiSse(
    alloc: Allocator,
    reader: anytype,
    events: *stream_provider.EventSink,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var content_buf: std.ArrayList(u8) = .empty;
    errdefer content_buf.deinit(alloc);

    var streamed_tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (streamed_tools.items) |*tool| tool.deinit(alloc);
        streamed_tools.deinit(alloc);
    }

    var finish_reason: ?types.ProviderFinishReason = null;

    var event_reader = SseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const event = try event_reader.next(alloc, reader);
        defer event_reader.releaseLine();

        switch (event) {
            .data => |json_text| {
                try handleOpenAiChunk(
                    alloc,
                    json_text,
                    &content_buf,
                    &streamed_tools,
                    &finish_reason,
                    events,
                    content_capture_limit,
                );
            },
            .done => break,
            .ignored => continue,
            .read_failed => {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                return error.ReadFailed;
            },
            .eof => break,
        }
    }

    if (finish_reason == null) {
        if (streamed_tools.items.len > 0) {
            finish_reason = .tool_calls;
        } else if (content_buf.items.len > 0) {
            finish_reason = .stop;
        }
    }

    const owned_content: ?[]u8 = if (content_buf.items.len > 0) try content_buf.toOwnedSlice(alloc) else null;
    if (owned_content != null) content_buf = .empty;
    errdefer if (owned_content) |value| alloc.free(value);

    const owned_tools: []types.ToolCall = if (streamed_tools.items.len > 0)
        try alloc.alloc(types.ToolCall, streamed_tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    const initialized: usize = 0;
    _ = &initialized;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    var count: usize = 0;
    for (streamed_tools.items) |tool| {
        if (tool.id.items.len == 0 or tool.name.items.len == 0) continue;
        owned_tools[count] = try dupeStreamedToolCall(alloc, tool);
        count += 1;
    }

    return .{
        .content = owned_content,
        .tool_calls = owned_tools[0..count],
        .finish_reason = finish_reason orelse if (count > 0) .tool_calls else .stop,
    };
}

fn emitContent(events: *stream_provider.EventSink, chunk: []const u8) void {
    events.emit(.{ .content_delta = chunk });
}

fn emitToolStart(events: *stream_provider.EventSink, id: []const u8, name: []const u8) void {
    events.emit(.{ .tool_started = .{ .id = id, .name = name, .label = null } });
}

fn emitToolInput(events: *stream_provider.EventSink, chunk: []const u8) void {
    events.emit(.{ .tool_input_delta = chunk });
}

const SseEvent = union(enum) {
    data: []const u8,
    done,
    ignored,
    read_failed,
    eof,
};

const SseEventReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    max_line_bytes: usize,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn releaseLine(self: *@This()) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *@This(), alloc: Allocator, reader: anytype) !SseEvent {
        const line = switch (try self.readLine(alloc, reader)) {
            .line => |value| value,
            .read_failed => return .read_failed,
            .eof => return .eof,
        };

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return .ignored;
        if (trimmed[0] == ':') return .ignored;
        const data_prefix = "data: ";
        if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .ignored;
        const json_text = trimmed[data_prefix.len..];
        if (std.mem.eql(u8, json_text, "[DONE]")) return .done;
        return .{ .data = json_text };
    }

    fn readLine(self: *@This(), alloc: Allocator, reader: anytype) !union(enum) {
        line: []const u8,
        read_failed,
        eof,
    } {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAiSseReadStalled;
                    if (buffered.len > self.max_line_bytes - self.pending_line.items.len) {
                        return error.OpenAiSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };

            if (fragment.len > self.max_line_bytes - self.pending_line.items.len) {
                return error.OpenAiSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

const StreamedToolCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn dupeStreamedToolCall(alloc: Allocator, tool: StreamedToolCall) !types.ToolCall {
    const args = if (tool.arguments.items.len == 0) "{}" else tool.arguments.items;
    if (try types.ToolArgumentIntegrity.classifySerialized(alloc, args) == .malformed_json) {
        return error.InvalidOpenAiResponse;
    }
    const id = try alloc.dupe(u8, tool.id.items);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, tool.name.items);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, args);
    errdefer alloc.free(arguments_json);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
    };
}

fn handleOpenAiChunk(
    alloc: Allocator,
    json_text: []const u8,
    content_buf: *std.ArrayList(u8),
    streamed_tools: *std.ArrayList(StreamedToolCall),
    finish_reason: *?types.ProviderFinishReason,
    events: *stream_provider.EventSink,
    content_capture_limit: ?usize,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const choices = parsed.value.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;

    if (choice.object.get("finish_reason")) |reason_value| {
        if (reason_value == .string and reason_value.string.len > 0) {
            finish_reason.* = types.ProviderFinishReason.parse_legacy(reason_value.string);
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |content_value| {
        if (content_value == .string and content_value.string.len > 0) {
            const retained = if (content_capture_limit) |limit|
                content_value.string[0..@min(content_value.string.len, limit -| content_buf.items.len)]
            else
                content_value.string;
            try content_buf.appendSlice(alloc, retained);
            emitContent(events, content_value.string);
        }
    }

    const tool_calls = delta.object.get("tool_calls") orelse return;
    if (tool_calls != .array) return;

    for (tool_calls.array.items) |tool_call| {
        if (tool_call != .object) continue;
        const index_value = tool_call.object.get("index") orelse continue;
        const index = validatedStreamedToolIndex(index_value) orelse return error.InvalidOpenAiResponse;
        while (streamed_tools.items.len <= index) {
            try streamed_tools.append(alloc, .{});
        }
        const record = &streamed_tools.items[index];

        if (tool_call.object.get("id")) |id_value| {
            if (id_value == .string and id_value.string.len > 0) {
                record.id.clearRetainingCapacity();
                try record.id.appendSlice(alloc, id_value.string);
            }
        }

        const function = tool_call.object.get("function") orelse continue;
        if (function != .object) continue;

        if (function.object.get("name")) |name_value| {
            if (name_value == .string and name_value.string.len > 0) {
                record.name.clearRetainingCapacity();
                try record.name.appendSlice(alloc, name_value.string);
                if (!record.announced and record.id.items.len > 0) {
                    record.announced = true;
                    emitToolStart(events, record.id.items, record.name.items);
                }
            }
        }

        if (function.object.get("arguments")) |args_value| {
            if (args_value == .string and args_value.string.len > 0) {
                try record.arguments.appendSlice(alloc, args_value.string);
                emitToolInput(events, args_value.string);
            }
        }
    }
}

fn validatedStreamedToolIndex(index_value: std.json.Value) ?usize {
    if (index_value != .integer) return null;
    if (index_value.integer < 0) return null;
    const index = std.math.cast(usize, index_value.integer) orelse return null;
    if (index > openai_transport.max_streamed_tool_index) return null;
    return index;
}

const RecordedToolStart = struct {
    id: []u8,
    name: []u8,
};

const TestEventSink = struct {
    sink: stream_provider.EventSink,
    contents: std.ArrayList(u8) = .empty,
    tool_inputs: std.ArrayList([]u8) = .empty,
    tool_starts: std.ArrayList(RecordedToolStart) = .empty,

    fn init() TestEventSink {
        return .{ .sink = .{
            .context = undefined,
            .emit_fn = emit,
        } };
    }

    fn deinit(self: *TestEventSink) void {
        const alloc = std.testing.allocator;
        self.contents.deinit(alloc);
        for (self.tool_inputs.items) |item| alloc.free(item);
        self.tool_inputs.deinit(alloc);
        for (self.tool_starts.items) |item| {
            alloc.free(item.id);
            alloc.free(item.name);
        }
        self.tool_starts.deinit(alloc);
    }

    fn emit(context: *anyopaque, event: stream_provider.Event) void {
        const self: *TestEventSink = @ptrCast(@alignCast(context));
        const alloc = std.testing.allocator;
        switch (event) {
            .content_delta => |chunk| self.contents.appendSlice(alloc, chunk) catch {},
            .tool_input_delta => |chunk| {
                const owned = alloc.dupe(u8, chunk) catch return;
                self.tool_inputs.append(alloc, owned) catch {
                    alloc.free(owned);
                };
            },
            .tool_started => |start| {
                self.tool_starts.append(alloc, .{
                    .id = alloc.dupe(u8, start.id) catch return,
                    .name = alloc.dupe(u8, start.name) catch return,
                }) catch {};
            },
            .reasoning_delta => {},
        }
    }
};

test "handleOpenAiChunk accumulates streamed tool call fragments" {
    const testing = std.testing;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    var tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(testing.allocator);
        tools.deinit(testing.allocator);
    }
    var finish: ?types.ProviderFinishReason = null;

    var sink = TestEventSink.init();
    defer sink.deinit();
    sink.sink.context = @ptrCast(&sink);

    const chunk1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}
    ;
    try handleOpenAiChunk(
        testing.allocator,
        chunk1,
        &content,
        &tools,
        &finish,
        &sink.sink,
        null,
    );

    const chunk2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"/tmp\"}"}}]}}]}
    ;
    try handleOpenAiChunk(
        testing.allocator,
        chunk2,
        &content,
        &tools,
        &finish,
        &sink.sink,
        null,
    );

    try testing.expectEqual(@as(usize, 1), tools.items.len);
    try testing.expectEqualStrings("call_1", tools.items[0].id.items);
    try testing.expectEqualStrings("read_file", tools.items[0].name.items);
    try testing.expectEqualStrings("{\"path\":\"/tmp\"}", tools.items[0].arguments.items);
    try testing.expectEqual(@as(usize, 1), sink.tool_starts.items.len);
    try testing.expectEqualStrings("call_1", sink.tool_starts.items[0].id);
    try testing.expectEqual(@as(usize, 2), sink.tool_inputs.items.len);
    try testing.expectEqualStrings("{\"path\":", sink.tool_inputs.items[0]);
    try testing.expectEqualStrings("\"/tmp\"}", sink.tool_inputs.items[1]);
}
