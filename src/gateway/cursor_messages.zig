//! The Cursor agent messages proto-fx sends and reads (D200), with field
//! numbers from proto's `providers/cursor/proto/agent.proto` (agent.v1).
//! Client messages are encoded whole; server messages decode into the small
//! union the reducer needs, borrowing from the frame.
const std = @import("std");
const pb = @import("cursor_protobuf.zig");
const Allocator = std.mem.Allocator;

/// What a handed-off MCP call returns to Cursor: proto's
/// `cursor-external-tool-handoff.md`, so the model ends the turn and
/// proto-fx runs the tool itself (D203).
pub const handoff_message = "Tool call received and handed off to the external client for execution. Do not retry or call it again; end the turn. The result will be provided in the next request.";

/// Why Cursor's own tools are refused: proto-fx runs every tool through its
/// own permission path, so the model must use the tools it was given.
pub const native_tool_refusal = "Tool not available in this client. Use the provided MCP tools instead: read_file to read, shell to run commands, write_file and edit_file to change files.";

// AgentClientMessage
const client_run_request = 1;
const client_exec = 2;
const client_kv = 3;
const client_exec_control = 5;
const client_interaction_response = 6;
const client_heartbeat = 7;

/// AgentClientMessage{run_request}. Caller owns the bytes.
pub fn runRequestMessage(alloc: Allocator, run_request: []const u8) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    errdefer w.deinit();
    try w.bytesField(client_run_request, run_request);
    return w.toOwned();
}

pub fn heartbeatMessage(alloc: Allocator) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    errdefer w.deinit();
    try w.emptyField(client_heartbeat);
    return w.toOwned();
}

/// KvClientMessage{id, get_blob_result{blob_data?}}.
pub fn getBlobResult(alloc: Allocator, id: u64, data: ?[]const u8) Allocator.Error![]u8 {
    var result = pb.Writer.init(alloc);
    defer result.deinit();
    if (data) |bytes| try result.bytesField(1, bytes);
    var kv = pb.Writer.init(alloc);
    defer kv.deinit();
    try kv.uintField(1, id);
    try kv.bytesField(2, result.bytes.items);
    return wrap(alloc, client_kv, kv.bytes.items);
}

/// KvClientMessage{id, set_blob_result{}}.
pub fn setBlobResult(alloc: Allocator, id: u64) Allocator.Error![]u8 {
    var kv = pb.Writer.init(alloc);
    defer kv.deinit();
    try kv.uintField(1, id);
    try kv.emptyField(3);
    return wrap(alloc, client_kv, kv.bytes.items);
}

fn wrap(alloc: Allocator, field: u32, inner: []const u8) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    errdefer w.deinit();
    try w.bytesField(field, inner);
    return w.toOwned();
}

/// ExecClientMessage{id, exec_id, <result_field>: result}.
pub fn execResult(alloc: Allocator, id: u64, exec_id: []const u8, result_field: u32, result: []const u8) Allocator.Error![]u8 {
    var exec = pb.Writer.init(alloc);
    defer exec.deinit();
    try exec.uintField(1, id);
    try exec.stringField(15, exec_id);
    try exec.bytesField(result_field, result);
    return wrap(alloc, client_exec, exec.bytes.items);
}

/// ExecClientControlMessage{stream_close{id}}.
pub fn execStreamClose(alloc: Allocator, id: u64) Allocator.Error![]u8 {
    var close = pb.Writer.init(alloc);
    defer close.deinit();
    try close.uintField(1, id);
    var control = pb.Writer.init(alloc);
    defer control.deinit();
    try control.bytesField(1, close.bytes.items);
    return wrap(alloc, client_exec_control, control.bytes.items);
}

/// ExecClientControlMessage{throw{id, error, error_code}}.
pub fn execThrow(alloc: Allocator, id: u64, message: []const u8, code: []const u8) Allocator.Error![]u8 {
    var throw = pb.Writer.init(alloc);
    defer throw.deinit();
    try throw.uintField(1, id);
    try throw.stringField(2, message);
    try throw.stringField(4, code);
    var control = pb.Writer.init(alloc);
    defer control.deinit();
    try control.bytesField(2, throw.bytes.items);
    return wrap(alloc, client_exec_control, control.bytes.items);
}

/// InteractionResponse{id, <field>: response}.
pub fn interactionResponse(alloc: Allocator, id: u64, field: u32, response: []const u8) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    defer w.deinit();
    try w.uintField(1, id);
    try w.bytesField(field, response);
    return wrap(alloc, client_interaction_response, w.bytes.items);
}

/// McpResult{success{content[text], is_error=false}}.
pub fn mcpTextResult(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var content = pb.Writer.init(alloc);
    defer content.deinit();
    try content.bytesField(1, text);
    var item = pb.Writer.init(alloc);
    defer item.deinit();
    try item.bytesField(1, content.bytes.items);
    var success = pb.Writer.init(alloc);
    defer success.deinit();
    try success.bytesField(1, item.bytes.items);
    return wrap(alloc, 1, success.bytes.items);
}

/// McpResult{approved{}}.
pub fn mcpApproved(alloc: Allocator) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    errdefer w.deinit();
    try w.emptyField(7);
    return w.toOwned();
}

/// `{1: path, 2: reason}` wrapped in oneof `field`: the rejected shape of
/// ReadResult, WriteResult, DeleteResult, LsResult, DiagnosticsResult and
/// FetchResult's error.
pub fn pathRejection(alloc: Allocator, field: u32, path: []const u8, reason: []const u8) Allocator.Error![]u8 {
    var inner = pb.Writer.init(alloc);
    defer inner.deinit();
    try inner.stringField(1, path);
    try inner.stringField(2, reason);
    return wrap(alloc, field, inner.bytes.items);
}

/// ShellRejected{command, working_directory, reason}.
pub fn shellRejected(alloc: Allocator, command: []const u8, working_directory: []const u8, reason: []const u8) Allocator.Error![]u8 {
    var w = pb.Writer.init(alloc);
    errdefer w.deinit();
    try w.stringField(1, command);
    try w.stringField(2, working_directory);
    try w.stringField(3, reason);
    return w.toOwned();
}

/// `{field: {1: text}}`.
pub fn textOneof(alloc: Allocator, field: u32, text: []const u8) Allocator.Error![]u8 {
    var inner = pb.Writer.init(alloc);
    defer inner.deinit();
    try inner.stringField(1, text);
    return wrap(alloc, field, inner.bytes.items);
}

// ExecServerMessage cases proto-fx answers.
pub const ExecCase = enum(u32) {
    shell = 2,
    write = 3,
    delete = 4,
    grep = 5,
    read = 7,
    ls = 8,
    diagnostics = 9,
    request_context = 10,
    mcp = 11,
    shell_stream = 14,
    background_shell_spawn = 16,
    fetch = 20,
    redacted_read = 29,
    _,
};

pub const McpCall = struct {
    name: []const u8 = "",
    tool_name: []const u8 = "",
    tool_call_id: []const u8 = "",
    /// The encoded `map<string, bytes>` entries, each a google.protobuf.Value.
    args: []const []const u8 = &.{},
    approval_only: bool = false,

    pub fn displayName(self: McpCall) []const u8 {
        return if (self.tool_name.len != 0) self.tool_name else self.name;
    }

    /// The arguments as one JSON object.
    pub fn writeArgsJson(self: McpCall, alloc: Allocator, out: *std.Io.Writer) !void {
        try out.writeByte('{');
        for (self.args, 0..) |entry, index| {
            if (index != 0) try out.writeByte(',');
            try std.json.Stringify.value((try pb.findBytes(entry, 1)) orelse "", .{}, out);
            try out.writeByte(':');
            try writeArgValue(alloc, out, (try pb.findBytes(entry, 2)) orelse "");
        }
        try out.writeByte('}');
    }
};

/// One argument: a google.protobuf.Value, or raw UTF-8 JSON text from older
/// builds (proto's `decodeMcpArgValue`).
fn writeArgValue(alloc: Allocator, out: *std.Io.Writer, bytes: []const u8) !void {
    if (looksLikeValue(bytes)) {
        var probe: std.Io.Writer.Discarding = .init(&.{});
        if (pb.writeValueJson(&probe.writer, bytes)) |_| return pb.writeValueJson(out, bytes) else |_| {}
    }
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.json.validate(alloc, trimmed) catch false) return out.writeAll(trimmed);
    try std.json.Stringify.value(bytes, .{}, out);
}

fn looksLikeValue(bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    return switch (bytes[0]) {
        0x08, 0x11, 0x1a, 0x20, 0x2a, 0x32 => true,
        else => false,
    };
}

pub const ServerMessage = union(enum) {
    text_delta: []const u8,
    thinking_delta: []const u8,
    thinking_completed,
    tool_call_started: ToolCallUpdate,
    partial_tool_call: ToolCallUpdate,
    tool_call_completed: ToolCallUpdate,
    token_delta: u64,
    turn_ended: TurnUsage,
    heartbeat,
    kv_get: struct { id: u64, blob_id: []const u8 },
    kv_set: struct { id: u64, blob_id: []const u8, data: []const u8 },
    exec: Exec,
    interaction_query: struct { id: u64, field: u32 },
    checkpoint: struct { used_tokens: u64 },
    ignored,
};

pub const ToolCallUpdate = struct {
    call_id: []const u8 = "",
    /// The envelope's tool_call_id (ToolCall field 57), when present.
    tool_call_id: []const u8 = "",
    mcp: ?McpCall = null,
    args_text: []const u8 = "",
};

pub const TurnUsage = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_read: ?u64 = null,
    cache_write: ?u64 = null,
    reasoning: ?u64 = null,
};

pub const Exec = struct {
    id: u64 = 0,
    exec_id: []const u8 = "",
    case: ExecCase = @fromBackingInt(@intCast(0)),
    /// The case's args message.
    args: []const u8 = "",
    mcp: ?McpCall = null,
};

/// Decodes one AgentServerMessage. `arena` holds argument lists; every
/// slice borrows `bytes` or `arena`.
pub fn decodeServerMessage(arena: Allocator, bytes: []const u8) !ServerMessage {
    var reader = pb.Reader.init(bytes);
    while (try reader.next()) |field| {
        if (field.wire != .bytes) continue;
        switch (field.number) {
            1 => return decodeInteractionUpdate(arena, field.data),
            2 => return .{ .exec = try decodeExec(arena, field.data) },
            3 => {
                const details = (try pb.findBytes(field.data, 5)) orelse "";
                return .{ .checkpoint = .{ .used_tokens = (try pb.findInt(details, 1)) orelse 0 } };
            },
            4 => return decodeKv(field.data),
            7 => {
                var query = pb.Reader.init(field.data);
                var id: u64 = 0;
                var case: u32 = 0;
                while (try query.next()) |item| {
                    if (item.number == 1 and item.wire == .varint) id = item.int else if (item.wire == .bytes) case = item.number;
                }
                return .{ .interaction_query = .{ .id = id, .field = case } };
            },
            else => {},
        }
    }
    return .ignored;
}

fn decodeInteractionUpdate(arena: Allocator, bytes: []const u8) !ServerMessage {
    var reader = pb.Reader.init(bytes);
    while (try reader.next()) |field| {
        if (field.wire != .bytes) continue;
        const value = field.data;
        switch (field.number) {
            1 => return .{ .text_delta = (try pb.findBytes(value, 1)) orelse "" },
            4 => return .{ .thinking_delta = (try pb.findBytes(value, 1)) orelse "" },
            5 => return .thinking_completed,
            2 => return .{ .tool_call_started = try decodeToolCallUpdate(arena, value, 0) },
            7 => return .{ .partial_tool_call = try decodeToolCallUpdate(arena, value, 3) },
            3 => return .{ .tool_call_completed = try decodeToolCallUpdate(arena, value, 0) },
            8 => return .{ .token_delta = (try pb.findInt(value, 1)) orelse 0 },
            13 => return .heartbeat,
            14 => {
                var usage: TurnUsage = .{};
                var fields = pb.Reader.init(value);
                while (try fields.next()) |item| {
                    if (item.wire != .varint) continue;
                    switch (item.number) {
                        1 => usage.input = item.int,
                        2 => usage.output = item.int,
                        3 => usage.cache_read = item.int,
                        4 => usage.cache_write = item.int,
                        5 => usage.reasoning = item.int,
                        else => {},
                    }
                }
                return .{ .turn_ended = usage };
            },
            else => return .ignored,
        }
    }
    return .ignored;
}

/// ToolCallStarted/Completed {1 call_id, 2 tool_call} or PartialToolCall
/// {1 call_id, 2 tool_call, 3 args_text_delta}.
fn decodeToolCallUpdate(arena: Allocator, bytes: []const u8, args_text_field: u32) !ToolCallUpdate {
    var update: ToolCallUpdate = .{};
    var reader = pb.Reader.init(bytes);
    while (try reader.next()) |field| {
        if (field.wire != .bytes) continue;
        if (field.number == 1) update.call_id = field.data;
        if (field.number == args_text_field) update.args_text = field.data;
        if (field.number == 2) {
            update.tool_call_id = (try pb.findBytes(field.data, 57)) orelse "";
            if (try pb.findBytes(field.data, 15)) |mcp_tool_call| {
                if (try pb.findBytes(mcp_tool_call, 1)) |args| update.mcp = try decodeMcpArgs(arena, args);
            }
        }
    }
    return update;
}

/// McpArgs {1 name, 2 args map, 3 tool_call_id, 5 tool_name, 7 approval only}.
pub fn decodeMcpArgs(arena: Allocator, bytes: []const u8) !McpCall {
    var call: McpCall = .{};
    var args: std.ArrayList([]const u8) = .empty;
    var reader = pb.Reader.init(bytes);
    while (try reader.next()) |field| switch (field.number) {
        1 => call.name = field.string(),
        2 => if (field.wire == .bytes) try args.append(arena, field.data),
        3 => call.tool_call_id = field.string(),
        5 => call.tool_name = field.string(),
        7 => call.approval_only = field.wire == .varint and field.int != 0,
        else => {},
    };
    call.args = args.items;
    return call;
}

fn decodeExec(arena: Allocator, bytes: []const u8) !Exec {
    var exec: Exec = .{};
    var reader = pb.Reader.init(bytes);
    while (try reader.next()) |field| switch (field.number) {
        1 => exec.id = field.int,
        15 => exec.exec_id = field.string(),
        19 => {},
        else => if (field.wire == .bytes) {
            exec.case = @fromBackingInt(@intCast(field.number));
            exec.args = field.data;
        },
    };
    if (exec.case == .mcp) exec.mcp = try decodeMcpArgs(arena, exec.args);
    return exec;
}

fn decodeKv(bytes: []const u8) !ServerMessage {
    var id: u64 = 0;
    var reader = pb.Reader.init(bytes);
    var get: ?[]const u8 = null;
    var set: ?[]const u8 = null;
    while (try reader.next()) |field| switch (field.number) {
        1 => id = field.int,
        2 => get = field.string(),
        3 => set = field.string(),
        else => {},
    };
    if (get) |args| return .{ .kv_get = .{ .id = id, .blob_id = (try pb.findBytes(args, 1)) orelse "" } };
    if (set) |args| return .{ .kv_set = .{ .id = id, .blob_id = (try pb.findBytes(args, 1)) orelse "", .data = (try pb.findBytes(args, 2)) orelse "" } };
    return .ignored;
}

test "proto's captured turn_ended frame decodes to its counters" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    // cursor-turn-frames.test.ts CAPTURED_TURN_ENDED: input 12336, output 36,
    // cache read and write 0, reasoning 31.
    var bytes: [15]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "0a0d720b08b060102418002000281f");
    const message = try decodeServerMessage(arena_state.allocator(), &bytes);
    const usage = message.turn_ended;
    try std.testing.expectEqual(@as(?u64, 12336), usage.input);
    try std.testing.expectEqual(@as(?u64, 36), usage.output);
    try std.testing.expectEqual(@as(?u64, 0), usage.cache_read);
    try std.testing.expectEqual(@as(?u64, 0), usage.cache_write);
    try std.testing.expectEqual(@as(?u64, 31), usage.reasoning);
}

test "an MCP exec decodes its call and arguments as JSON" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var mcp = pb.Writer.init(arena);
    try mcp.bytesField(1, "read_file");
    for ([_][2][]const u8{ .{ "path", "README.md" }, .{ "note", "{\"raw\":1}" } }) |pair| {
        var entry = pb.Writer.init(arena);
        try entry.bytesField(1, pair[0]);
        // The second argument is raw JSON text, as older builds send it.
        try entry.bytesField(2, if (std.mem.eql(u8, pair[0], "path")) try pb.encodeJsonValue(arena, .{ .string = pair[1] }) else pair[1]);
        try mcp.bytesField(2, entry.bytes.items);
    }
    try mcp.bytesField(3, "toolu_1");
    try mcp.bytesField(5, "read_file");
    var exec = pb.Writer.init(arena);
    try exec.uintField(1, 4);
    try exec.bytesField(15, "exec-9");
    try exec.bytesField(11, mcp.bytes.items);
    var server = pb.Writer.init(arena);
    try server.bytesField(2, exec.bytes.items);
    const message = try decodeServerMessage(arena, server.bytes.items);
    try std.testing.expectEqual(@as(u64, 4), message.exec.id);
    try std.testing.expectEqualStrings("exec-9", message.exec.exec_id);
    try std.testing.expectEqual(ExecCase.mcp, message.exec.case);
    const call = message.exec.mcp.?;
    try std.testing.expectEqualStrings("toolu_1", call.tool_call_id);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try call.writeArgsJson(alloc, &out.writer);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\",\"note\":{\"raw\":1}}", out.written());
}

test "client replies encode as proto's schemas expect" {
    const alloc = std.testing.allocator;
    const get = try getBlobResult(alloc, 3, "abc");
    defer alloc.free(get);
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x09, 0x08, 0x03, 0x12, 0x05, 0x0a, 0x03, 'a', 'b', 'c' }, get);
    const missing = try getBlobResult(alloc, 3, null);
    defer alloc.free(missing);
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x04, 0x08, 0x03, 0x12, 0x00 }, missing);
    const beat = try heartbeatMessage(alloc);
    defer alloc.free(beat);
    try std.testing.expectEqualSlices(u8, &.{ 0x3a, 0x00 }, beat);
    const handoff = try mcpTextResult(alloc, "ok");
    defer alloc.free(handoff);
    const reply = try execResult(alloc, 4, "exec-9", @backingInt(ExecCase.mcp), handoff);
    defer alloc.free(reply);
    const exec = (try pb.findBytes(reply, client_exec)).?;
    try std.testing.expectEqual(@as(u64, 4), (try pb.findInt(exec, 1)).?);
    try std.testing.expectEqualStrings("exec-9", (try pb.findBytes(exec, 15)).?);
    const success = (try pb.findBytes((try pb.findBytes(exec, 11)).?, 1)).?;
    const item = (try pb.findBytes(success, 1)).?;
    try std.testing.expectEqualStrings("ok", (try pb.findBytes((try pb.findBytes(item, 1)).?, 1)).?);
}
