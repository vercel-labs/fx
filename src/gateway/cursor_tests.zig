//! Request building and stream reduction for the Cursor transport, with
//! frames shaped like proto's cursor-stream and cursor-turn-frames tests.
const std = @import("std");
const pb = @import("cursor_protobuf.zig");
const msg = @import("cursor_messages.zig");
const cursor_request = @import("cursor_request.zig");
const reducer_mod = @import("cursor_stream.zig");
const streams = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");

const read_tool = [_]model_tool_schema.FunctionSchema{.{ .name = "read_file", .description = "Read a file." }};

fn baseRequest(messages: []const types.ChatMessage) streams.RequestData {
    return .{
        .model = "composer-2.5",
        .instructions = &.{.{ .role = .system, .content = "Be brief." }},
        .messages = messages,
        .tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &read_tool },
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

const model: cursor_request.Model = .{ .id = "composer-2.5", .wire_id = "composer-2.5", .name = "Composer 2.5" };

fn runRequest(run_message: []const u8) ![]const u8 {
    return (try pb.findBytes(run_message, 1)).?;
}

test "a trailing tool result resumes with the round as a conversation turn" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "read the readme" },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .tool_name = "read_file", .content = "# proto-fx" },
    };
    const built = try cursor_request.build(arena, baseRequest(&messages), .{ .model = model, .conversation_id = "conv-1" });
    const run = try runRequest(built.run_message);
    try std.testing.expectEqualStrings("conv-1", (try pb.findBytes(run, 5)).?);
    // ConversationAction.resume_action
    const action = (try pb.findBytes(run, 2)).?;
    try std.testing.expect(try pb.findBytes(action, 2) != null);
    try std.testing.expect(try pb.findBytes(action, 1) == null);
    const state = (try pb.findBytes(run, 1)).?;
    // Root prompt: the system prompt, then user, assistant and tool JSON.
    var roots: std.ArrayList([]const u8) = .empty;
    var reader = pb.Reader.init(state);
    var turn_id: ?[]const u8 = null;
    while (try reader.next()) |field| {
        if (field.number == 1) try roots.append(arena, built.blobs.get(field.data[0..32].*).?);
        if (field.number == 8) turn_id = field.data;
    }
    try std.testing.expectEqual(@as(usize, 4), roots.items.len);
    try std.testing.expectEqualStrings("{\"role\":\"system\",\"content\":\"Be brief.\"}", roots.items[0]);
    try std.testing.expectEqualStrings("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"read the readme\"}]}", roots.items[1]);
    try std.testing.expectEqualStrings("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Reading.\"},{\"type\":\"tool-call\",\"toolCallId\":\"toolu_1\",\"toolName\":\"read_file\",\"args\":{\"path\":\"README.md\"}}]}", roots.items[2]);
    try std.testing.expectEqualStrings("{\"role\":\"tool\",\"id\":\"toolu_1\",\"content\":[{\"type\":\"tool-result\",\"toolName\":\"read_file\",\"toolCallId\":\"toolu_1\",\"result\":\"# proto-fx\"}]}", roots.items[3]);
    // The turn: user message blob, then the text step and the MCP call step
    // carrying its result.
    const turn = (try pb.findBytes(built.blobs.get(turn_id.?[0..32].*).?, 1)).?;
    var steps: std.ArrayList([]const u8) = .empty;
    var user_blob: ?[]const u8 = null;
    reader = pb.Reader.init(turn);
    while (try reader.next()) |field| {
        if (field.number == 1) user_blob = built.blobs.get(field.data[0..32].*).?;
        if (field.number == 2) try steps.append(arena, built.blobs.get(field.data[0..32].*).?);
    }
    try std.testing.expectEqualStrings("read the readme", (try pb.findBytes(user_blob.?, 1)).?);
    try std.testing.expectEqual(@as(usize, 2), steps.items.len);
    try std.testing.expectEqualStrings("Reading.", (try pb.findBytes((try pb.findBytes(steps.items[0], 1)).?, 1)).?);
    const tool_call = (try pb.findBytes(steps.items[1], 2)).?;
    try std.testing.expectEqualStrings("toolu_1", (try pb.findBytes(tool_call, 57)).?);
    const mcp = (try pb.findBytes(tool_call, 15)).?;
    const args = try msg.decodeMcpArgs(arena, (try pb.findBytes(mcp, 1)).?);
    try std.testing.expectEqualStrings("read_file", args.tool_name);
    var json: std.Io.Writer.Allocating = .init(arena);
    try args.writeArgsJson(arena, &json.writer);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", json.written());
    const result = (try pb.findBytes(mcp, 2)).?;
    const item = (try pb.findBytes((try pb.findBytes(result, 1)).?, 1)).?;
    try std.testing.expectEqualStrings("# proto-fx", (try pb.findBytes((try pb.findBytes(item, 1)).?, 1)).?);
    // Model selection on both the legacy and the requested fields.
    try std.testing.expectEqualStrings("composer-2.5", (try pb.findBytes((try pb.findBytes(run, 3)).?, 1)).?);
    try std.testing.expectEqualStrings("composer-2.5", (try pb.findBytes((try pb.findBytes(run, 9)).?, 1)).?);
    // The request context carries the rule and the tool as MCP.
    const definition = (try pb.findBytes(built.request_context, 7)).?;
    try std.testing.expectEqualStrings("read_file", (try pb.findBytes(definition, 1)).?);
    try std.testing.expectEqualStrings(cursor_request.provider_identifier, (try pb.findBytes(definition, 4)).?);
    var schema: std.Io.Writer.Allocating = .init(arena);
    try pb.writeValueJson(&schema.writer, (try pb.findBytes(definition, 3)).?);
    try std.testing.expect(std.mem.startsWith(u8, schema.written(), "{\"type\":\"object\""));
    const rule = (try pb.findBytes(built.request_context, 2)).?;
    try std.testing.expectEqualStrings("Be brief.", (try pb.findBytes(rule, 2)).?);
}

test "a trailing user message is the user action and stays out of history" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "  hello  " }};
    const built = try cursor_request.build(arena, baseRequest(&messages), .{ .model = model, .conversation_id = "c" });
    const run = try runRequest(built.run_message);
    const user_action = (try pb.findBytes((try pb.findBytes(run, 2)).?, 1)).?;
    const user = (try pb.findBytes(user_action, 1)).?;
    try std.testing.expectEqualStrings("hello", (try pb.findBytes(user, 1)).?);
    try std.testing.expectEqual(@as(usize, 36), (try pb.findBytes(user, 2)).?.len);
    const state = (try pb.findBytes(run, 1)).?;
    try std.testing.expect(try pb.findBytes(state, 8) == null);
    // Packing keeps every part.
    const packed_bytes = try cursor_request.pack(std.testing.allocator, built);
    defer std.testing.allocator.free(packed_bytes);
    const unpacked = try cursor_request.unpack(arena, packed_bytes);
    try std.testing.expectEqualSlices(u8, built.run_message, unpacked.run_message);
    try std.testing.expectEqualSlices(u8, built.request_context, unpacked.request_context);
    try std.testing.expectEqual(built.blobs.count(), unpacked.blobs.count());
}

const Recorder = struct {
    events: std.ArrayList(u8) = .empty,

    fn emit(context: *anyopaque, event: streams.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const line = switch (event) {
            .content_delta => |text| std.fmt.allocPrint(std.testing.allocator, "text:{s}\n", .{text}),
            .reasoning_delta => |text| std.fmt.allocPrint(std.testing.allocator, "think:{s}\n", .{text}),
            .tool_started => |tool| std.fmt.allocPrint(std.testing.allocator, "tool:{s}:{s}\n", .{ tool.id, tool.name }),
            .tool_input_delta => |delta| std.fmt.allocPrint(std.testing.allocator, "args:{d}:{s}\n", .{ delta.index, delta.chunk }),
        } catch return;
        defer std.testing.allocator.free(line);
        self.events.appendSlice(std.testing.allocator, line) catch {};
    }

    fn sink(self: *Recorder) streams.EventSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

/// AgentServerMessage{interaction_update{<case>: inner}}.
fn update(arena: std.mem.Allocator, case: u32, inner: []const u8) ![]const u8 {
    var w = pb.Writer.init(arena);
    try w.bytesField(case, inner);
    var server = pb.Writer.init(arena);
    try server.bytesField(1, w.bytes.items);
    return server.bytes.items;
}

fn textOf(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var w = pb.Writer.init(arena);
    try w.bytesField(1, text);
    return w.bytes.items;
}

/// McpArgs with one string argument.
fn mcpArgs(arena: std.mem.Allocator, id: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var entry = pb.Writer.init(arena);
    try entry.bytesField(1, key);
    try entry.bytesField(2, try pb.encodeJsonValue(arena, .{ .string = value }));
    var args = pb.Writer.init(arena);
    try args.bytesField(1, "read_file");
    try args.bytesField(2, entry.bytes.items);
    try args.bytesField(3, id);
    try args.bytesField(4, "proto-fx");
    try args.bytesField(5, "read_file");
    return args.bytes.items;
}

/// McpArgs naming the tool with no arguments yet, as a started call has.
fn mcpHeader(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var args = pb.Writer.init(arena);
    try args.bytesField(1, "read_file");
    try args.bytesField(3, id);
    try args.bytesField(5, "read_file");
    return args.bytes.items;
}

fn toolCallUpdate(arena: std.mem.Allocator, call_id: []const u8, args: ?[]const u8, args_text: ?[]const u8) ![]const u8 {
    var w = pb.Writer.init(arena);
    try w.bytesField(1, call_id);
    if (args) |value| {
        var mcp = pb.Writer.init(arena);
        try mcp.bytesField(1, value);
        var tool_call = pb.Writer.init(arena);
        try tool_call.bytesField(15, mcp.bytes.items);
        try w.bytesField(2, tool_call.bytes.items);
    }
    if (args_text) |text| try w.bytesField(3, text);
    return w.bytes.items;
}

fn exec(arena: std.mem.Allocator, id: u64, case: msg.ExecCase, args: []const u8) ![]const u8 {
    var w = pb.Writer.init(arena);
    try w.uintField(1, id);
    try w.bytesField(15, "exec-1");
    try w.bytesField(@backingInt(case), args);
    var server = pb.Writer.init(arena);
    try server.bytesField(2, w.bytes.items);
    return server.bytes.items;
}

const inline_png_bytes = "\x89PNG\r\n\x1a\n";
const inline_png_sha256 = "4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6";

fn inlinePngAttachment() types.ImageAttachment {
    return .{
        .path = @constCast("inline.png"),
        .media_type = @constCast("image/png"),
        .snapshot_sha256 = @constCast(inline_png_sha256),
        .inline_data = @constCast(inline_png_bytes),
    };
}

test "Cursor sends verified active and historical user images" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const active_image = inlinePngAttachment();
    const active_images = [_]types.ImageAttachment{active_image};
    const active_messages = [_]types.ChatMessage{.{
        .role = .user,
        .content = "inspect this",
        .images = &active_images,
    }};
    const active = try cursor_request.build(arena, baseRequest(&active_messages), .{
        .model = model,
        .conversation_id = "active-image",
    });
    const active_run = try runRequest(active.run_message);
    const action = (try pb.findBytes(active_run, 2)).?;
    const user_action = (try pb.findBytes(action, 1)).?;
    const active_user = (try pb.findBytes(user_action, 1)).?;
    const selected_context = (try pb.findBytes(active_user, 3)).?;
    const selected_image = (try pb.findBytes(selected_context, 1)).?;
    try std.testing.expectEqual(@as(usize, 36), (try pb.findBytes(selected_image, 2)).?.len);
    try std.testing.expectEqualStrings("image/png", (try pb.findBytes(selected_image, 7)).?);
    try std.testing.expectEqualSlices(u8, inline_png_bytes, (try pb.findBytes(selected_image, 8)).?);

    const history_image = inlinePngAttachment();
    const history_images = [_]types.ImageAttachment{history_image};
    const history_messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "old image", .images = &history_images },
        .{ .role = .user, .content = "new text" },
    };
    const historical = try cursor_request.build(arena, baseRequest(&history_messages), .{
        .model = model,
        .conversation_id = "history-image",
    });
    const historical_run = try runRequest(historical.run_message);
    const state = (try pb.findBytes(historical_run, 1)).?;
    var roots = pb.Reader.init(state);
    var root_count: usize = 0;
    var historical_user: ?[]const u8 = null;
    while (try roots.next()) |field| {
        if (field.number != 1) continue;
        const blob = historical.blobs.get(field.data[0..32].*).?;
        if (root_count == 1) historical_user = blob;
        root_count += 1;
    }
    try std.testing.expect(historical_user != null);
    try std.testing.expect(std.mem.indexOf(u8, historical_user.?, "data:image/png;base64,iVBORw0KGgo=") != null);
    try std.testing.expect(std.mem.indexOf(u8, historical_user.?, "\"mediaType\":\"image/png\"") != null);
}

test "a recorded tool turn streams text, reasoning and arguments and hands the call off" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "read it" }};
    var built = try cursor_request.build(arena, baseRequest(&messages), .{ .model = model, .conversation_id = "c" });
    var recorder: Recorder = .{};
    defer recorder.events.deinit(alloc);
    var state = reducer_mod.Reducer.init(alloc, baseRequest(&messages), &built.blobs, built.request_context, .{});
    defer state.deinit();

    var some_blob: ?[32]u8 = null;
    var iterator = built.blobs.keyIterator();
    some_blob = iterator.next().?.*;
    var kv_get = pb.Writer.init(arena);
    {
        var args = pb.Writer.init(arena);
        try args.bytesField(1, &some_blob.?);
        var kv = pb.Writer.init(arena);
        try kv.uintField(1, 7);
        try kv.bytesField(2, args.bytes.items);
        try kv_get.bytesField(4, kv.bytes.items);
    }
    var turn_ended = pb.Writer.init(arena);
    try turn_ended.uintField(1, 1200);
    try turn_ended.uintField(2, 40);
    try turn_ended.uintField(3, 1000);
    const frames = [_][]const u8{
        kv_get.bytes.items,
        try exec(arena, 1, .request_context, ""),
        try update(arena, 4, try textOf(arena, "Plan: read.")),
        try update(arena, 5, ""),
        try update(arena, 1, try textOf(arena, "Reading.")),
        try update(arena, 2, try toolCallUpdate(arena, "call-1", try mcpHeader(arena, "call-1"), null)),
        try update(arena, 7, try toolCallUpdate(arena, "call-1", null, "{\"path\":")),
        try update(arena, 7, try toolCallUpdate(arena, "call-1", null, "{\"path\":\"README.md\"}")),
        try exec(arena, 2, .mcp, try mcpArgs(arena, "call-1", "path", "README.md")),
        try update(arena, 3, try toolCallUpdate(arena, "call-1", try mcpArgs(arena, "call-1", "path", "README.md"), null)),
        try update(arena, 8, try textOf(arena, "")),
        try update(arena, 14, turn_ended.bytes.items),
    };
    var replies: std.ArrayList([]const u8) = .empty;
    for (frames) |frame| {
        const message = try msg.decodeServerMessage(arena, frame);
        try state.accept(arena, message, recorder.sink());
        for (state.pendingReplies()) |reply| try replies.append(arena, try arena.dupe(u8, reply));
        state.freeReplies();
    }
    try std.testing.expectEqualStrings(
        "think:Plan: read.\ntext:Reading.\ntool:call-1:read_file\nargs:0:{\"path\":\nargs:0:\"README.md\"}\n",
        recorder.events.items,
    );
    // Replies: the blob, the request context, the handoff.
    try std.testing.expectEqual(@as(usize, 3), replies.items.len);
    const kv = (try pb.findBytes(replies.items[0], 3)).?;
    try std.testing.expectEqual(@as(u64, 7), (try pb.findInt(kv, 1)).?);
    try std.testing.expectEqualStrings(built.blobs.get(some_blob.?).?, (try pb.findBytes((try pb.findBytes(kv, 2)).?, 1)).?);
    const context_reply = (try pb.findBytes(replies.items[1], 2)).?;
    const success = (try pb.findBytes((try pb.findBytes(context_reply, 10)).?, 1)).?;
    try std.testing.expectEqualSlices(u8, built.request_context, (try pb.findBytes(success, 1)).?);
    const handoff = (try pb.findBytes(replies.items[2], 2)).?;
    try std.testing.expectEqual(@as(u64, 2), (try pb.findInt(handoff, 1)).?);
    const result = (try pb.findBytes(handoff, 11)).?;
    const item = (try pb.findBytes((try pb.findBytes(result, 1)).?, 1)).?;
    try std.testing.expectEqualStrings(msg.handoff_message, (try pb.findBytes((try pb.findBytes(item, 1)).?, 1)).?);

    var finished = try state.finish();
    defer finished.deinit(alloc);
    const completion = finished.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call-1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 1200), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 40), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1000), completion.usage.cache_read_tokens);
}

test "Cursor's own tools are refused so proto-fx's tools run instead" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "x" }};
    var blobs: cursor_request.BlobStore = .empty;
    var state = reducer_mod.Reducer.init(alloc, baseRequest(&messages), &blobs, "", .{});
    defer state.deinit();
    var recorder: Recorder = .{};
    defer recorder.events.deinit(alloc);
    var read_args = pb.Writer.init(arena);
    try read_args.bytesField(1, "/etc/hosts");
    var shell_args = pb.Writer.init(arena);
    try shell_args.bytesField(1, "ls");
    try shell_args.bytesField(2, "/tmp");
    try state.accept(arena, try msg.decodeServerMessage(arena, try exec(arena, 5, .read, read_args.bytes.items)), recorder.sink());
    try state.accept(arena, try msg.decodeServerMessage(arena, try exec(arena, 6, .shell_stream, shell_args.bytes.items)), recorder.sink());
    const replies = state.pendingReplies();
    try std.testing.expectEqual(@as(usize, 3), replies.len);
    const read_result = (try pb.findBytes((try pb.findBytes(replies[0], 2)).?, 7)).?;
    const rejected = (try pb.findBytes(read_result, 3)).?;
    try std.testing.expectEqualStrings("/etc/hosts", (try pb.findBytes(rejected, 1)).?);
    try std.testing.expectEqualStrings(msg.native_tool_refusal, (try pb.findBytes(rejected, 2)).?);
    const shell_stream = (try pb.findBytes((try pb.findBytes(replies[1], 2)).?, 14)).?;
    const shell_rejected = (try pb.findBytes(shell_stream, 5)).?;
    try std.testing.expectEqualStrings("ls", (try pb.findBytes(shell_rejected, 1)).?);
    // The shell stream is closed after its refusal.
    const control = (try pb.findBytes(replies[2], 5)).?;
    try std.testing.expectEqual(@as(u64, 6), (try pb.findInt((try pb.findBytes(control, 1)).?, 1)).?);
    try std.testing.expectEqualStrings("", recorder.events.items);
    try std.testing.expectError(error.IncompleteStream, state.finish());
}
