//! The pure half of the Claude Code provider (`claude_code.zig`): what fx
//! writes to the `claude` process and its MCP bridge, what it reads back,
//! and how a request's history lines up with what the process already has.
//! Nothing here starts a process, opens a socket, or reads a clock.
//!
//! Claude Code runs the model loop and keeps its own transcript. fx keeps
//! its own history too, so every request must extend what the process has
//! already seen. `Unit` reduces a history to the parts both sides must agree
//! on: each user message's text, each tool call's id, and each tool result's
//! id. `planDelta` compares a request's units with the ones the process has
//! seen and says what to send, or that the two have diverged.
const std = @import("std");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const function_tools = @import("function_tools.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The MCP server name Claude Code sees. Its tools reach the model as
/// `mcp__fx__<name>`.
pub const server_name = "fx";
pub const tool_prefix = "mcp__" ++ server_name ++ "__";
/// Claude's tool names allow letters, digits, `_`, and `-`, up to 64 bytes
/// with the prefix.
pub const max_wire_name_bytes = 64 - tool_prefix.len;

// ---------------------------------------------------------------------------
// Tool names

/// Maps fx tool names to names Claude accepts and back. fx advertises dotted
/// names, which Claude's tool names can't carry, so those get `_` in their
/// place; a name that would collide gets a numeric suffix.
pub const ToolNames = struct {
    fx: std.ArrayList([]const u8) = .empty,
    wire: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ToolNames, alloc: Allocator) void {
        for (self.wire.items) |name| alloc.free(name);
        self.wire.deinit(alloc);
        self.fx.deinit(alloc);
        self.* = .{};
    }

    /// Adds `name`, borrowed until deinit, and returns its wire name.
    pub fn add(self: *ToolNames, alloc: Allocator, name: []const u8) ![]const u8 {
        var buf: [max_wire_name_bytes]u8 = undefined;
        const base_len = @min(name.len, max_wire_name_bytes);
        for (name[0..base_len], buf[0..base_len]) |byte, *out| {
            out.* = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') byte else '_';
        }
        var candidate: []const u8 = buf[0..base_len];
        var suffix: usize = 2;
        var suffixed: [max_wire_name_bytes]u8 = undefined;
        while (self.wireIndex(candidate) != null) : (suffix += 1) {
            var digits: [20]u8 = undefined;
            const tail = std.mem.print(&digits, "_{d}", .{suffix}) catch unreachable;
            const keep = @min(base_len, max_wire_name_bytes - tail.len);
            @memcpy(suffixed[0..keep], buf[0..keep]);
            @memcpy(suffixed[keep..][0..tail.len], tail);
            candidate = suffixed[0 .. keep + tail.len];
        }
        const owned = try alloc.dupe(u8, candidate);
        errdefer alloc.free(owned);
        try self.wire.append(alloc, owned);
        errdefer _ = self.wire.pop();
        try self.fx.append(alloc, name);
        return owned;
    }

    fn wireIndex(self: *const ToolNames, wire_name: []const u8) ?usize {
        for (self.wire.items, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, wire_name)) return index;
        }
        return null;
    }

    /// The fx name for a name Claude called, with or without the MCP
    /// prefix. Null for a tool fx never offered.
    pub fn fxName(self: *const ToolNames, called: []const u8) ?[]const u8 {
        const bare = if (std.mem.startsWith(u8, called, tool_prefix)) called[tool_prefix.len..] else called;
        const index = self.wireIndex(bare) orelse return null;
        return self.fx.items[index];
    }
};

test "claude code: tool names keep valid names and map dotted ones back" {
    const alloc = std.testing.allocator;
    var names: ToolNames = .{};
    defer names.deinit(alloc);
    try std.testing.expectEqualStrings("read_file", try names.add(alloc, "read_file"));
    try std.testing.expectEqualStrings("mcp_linear_list", try names.add(alloc, "mcp.linear.list"));
    try std.testing.expectEqualStrings("mcp_linear_list_2", try names.add(alloc, "mcp_linear_list"));
    try std.testing.expectEqualStrings("read_file", names.fxName("mcp__fx__read_file").?);
    try std.testing.expectEqualStrings("mcp.linear.list", names.fxName("mcp__fx__mcp_linear_list").?);
    try std.testing.expectEqualStrings("mcp_linear_list", names.fxName("mcp_linear_list_2").?);
    try std.testing.expect(names.fxName("mcp__fx__nope") == null);
}

/// Writes the MCP `tools/list` result for `functions` and records their
/// wire names in `names`.
pub fn writeToolsList(alloc: Allocator, writer: *Writer, functions: []const function_tools.Function, names: *ToolNames) !void {
    try writer.writeAll("{\"tools\":[");
    for (functions, 0..) |function, index| {
        if (index != 0) try writer.writeByte(',');
        const wire_name = try names.add(alloc, function.name);
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(wire_name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
        try writer.writeAll(",\"inputSchema\":");
        switch (function.schema) {
            .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
            .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

// ---------------------------------------------------------------------------
// The claude process's stdin

/// One user message on Claude Code's stream-json input.
pub fn writeUserMessage(writer: *Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}}\n");
}

/// Asks Claude Code to stop the turn it is running. It answers with a
/// `control_response` and ends the turn with a `result`.
pub fn writeInterrupt(writer: *Writer, request_id: []const u8) !void {
    try writer.writeAll("{\"type\":\"control_request\",\"request_id\":");
    try std.json.Stringify.value(request_id, .{}, writer);
    try writer.writeAll(",\"request\":{\"subtype\":\"interrupt\"}}\n");
}

test "claude code: stdin messages are single JSON lines" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeUserMessage(&out.writer, "line one\nline \"two\"");
    try writeInterrupt(&out.writer, "int-1");
    try std.testing.expectEqualStrings(
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"line one\\nline \\\"two\\\"\"}}\n" ++
            "{\"type\":\"control_request\",\"request_id\":\"int-1\",\"request\":{\"subtype\":\"interrupt\"}}\n",
        out.written(),
    );
}

// ---------------------------------------------------------------------------
// The claude process's stdout

pub const BlockKind = enum { text, thinking, tool_use, other };

/// What a Claude Code stream-json line means to a model step. Slices borrow
/// the arena the line was parsed into.
pub const StdoutLine = union(enum) {
    /// `system` `init`: the session and the model Claude Code resolved.
    init: struct { session_id: ?[]const u8, model: ?[]const u8 },
    message_start: struct { usage: Counts },
    block_start: struct { index: usize, kind: BlockKind, tool_id: ?[]const u8 = null, tool_name: ?[]const u8 = null },
    text_delta: []const u8,
    thinking_delta: []const u8,
    /// Partial tool-use input for the block at `index`.
    input_delta: struct { index: usize, partial_json: []const u8 },
    block_stop: usize,
    message_delta: struct { stop_reason: ?[]const u8, usage: Counts },
    message_stop,
    /// A complete `assistant` message: its tool uses, with their input, and
    /// the error Claude Code reports for a request that failed.
    assistant: struct { tool_uses: []const ToolUse, error_kind: ?[]const u8, text: ?[]const u8 },
    /// The end of a turn.
    result: Result,
    /// A `rate_limit_event` whose status is not `allowed`.
    rate_limited: struct { resets_at: ?i64 },
    control_response,
    /// Everything a step ignores, such as `user` echoes and status lines.
    other,
};

pub const Counts = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_read: ?u64 = null,
    cache_write: ?u64 = null,

    pub fn merge(self: *Counts, other: Counts) void {
        inline for (@typeInfo(Counts).@"struct".field_names) |name| {
            if (@field(other, name)) |value| @field(self, name) = value;
        }
    }

    pub fn usage(self: Counts) types.Usage {
        const reported = self.input != null or self.cache_read != null or self.cache_write != null;
        return .{
            .input_tokens = if (reported) (self.input orelse 0) +| (self.cache_read orelse 0) +| (self.cache_write orelse 0) else null,
            .output_tokens = self.output,
            .cache_read_tokens = self.cache_read,
            .cache_write_tokens = self.cache_write,
        };
    }
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

pub const Result = struct {
    is_error: bool,
    subtype: ?[]const u8,
    text: ?[]const u8,
    stop_reason: ?[]const u8,
    session_id: ?[]const u8,
    /// The `--json-schema` reply, serialized.
    structured_json: ?[]const u8,
};

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn countField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

fn parseCounts(usage: ?std.json.ObjectMap) Counts {
    const object = usage orelse return .{};
    return .{
        .input = countField(object, "input_tokens"),
        .output = countField(object, "output_tokens"),
        .cache_read = countField(object, "cache_read_input_tokens"),
        .cache_write = countField(object, "cache_creation_input_tokens"),
    };
}

fn indexField(object: std.json.ObjectMap) usize {
    return @intCast(countField(object, "index") orelse 0);
}

/// Parses one stdout line. A line that isn't a JSON object is `error.InvalidLine`.
pub fn parseStdoutLine(arena: Allocator, line: []const u8) !StdoutLine {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLine,
    };
    if (value != .object) return error.InvalidLine;
    const root = value.object;
    const kind = stringField(root, "type") orelse return .other;
    if (std.mem.eql(u8, kind, "stream_event")) {
        const event = objectField(root, "event") orelse return .other;
        // A subagent's events carry the tool use that started it; fx offers
        // no subagent tool, so they never belong to this step.
        if (root.get("parent_tool_use_id")) |parent| if (parent != .null) return .other;
        return parseStreamEvent(event);
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        if (root.get("parent_tool_use_id")) |parent| if (parent != .null) return .other;
        return parseAssistant(arena, root);
    }
    if (std.mem.eql(u8, kind, "result")) {
        var structured: ?[]const u8 = null;
        if (root.get("structured_output")) |output| if (output != .null) {
            structured = try std.json.Stringify.valueAlloc(arena, output, .{});
        };
        const is_error = if (root.get("is_error")) |flag| flag == .bool and flag.bool else false;
        return .{ .result = .{
            .is_error = is_error,
            .subtype = stringField(root, "subtype"),
            .text = stringField(root, "result"),
            .stop_reason = stringField(root, "stop_reason"),
            .session_id = stringField(root, "session_id"),
            .structured_json = structured,
        } };
    }
    if (std.mem.eql(u8, kind, "system")) {
        const subtype = stringField(root, "subtype") orelse return .other;
        if (!std.mem.eql(u8, subtype, "init")) return .other;
        return .{ .init = .{ .session_id = stringField(root, "session_id"), .model = stringField(root, "model") } };
    }
    if (std.mem.eql(u8, kind, "rate_limit_event")) {
        const info = objectField(root, "rate_limit_info") orelse return .other;
        const status = stringField(info, "status") orelse return .other;
        if (std.mem.eql(u8, status, "allowed") or std.mem.eql(u8, status, "allowed_warning")) return .other;
        const resets: ?i64 = if (info.get("resetsAt")) |at| (if (at == .integer) at.integer else null) else null;
        return .{ .rate_limited = .{ .resets_at = resets } };
    }
    if (std.mem.eql(u8, kind, "control_response")) return .control_response;
    return .other;
}

fn parseStreamEvent(event: std.json.ObjectMap) StdoutLine {
    const kind = stringField(event, "type") orelse return .other;
    if (std.mem.eql(u8, kind, "message_start")) {
        const message = objectField(event, "message") orelse return .{ .message_start = .{ .usage = .{} } };
        return .{ .message_start = .{ .usage = parseCounts(objectField(message, "usage")) } };
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const block = objectField(event, "content_block") orelse return .other;
        const block_type = stringField(block, "type") orelse return .other;
        const block_kind: BlockKind = if (std.mem.eql(u8, block_type, "text"))
            .text
        else if (std.mem.eql(u8, block_type, "thinking"))
            .thinking
        else if (std.mem.eql(u8, block_type, "tool_use"))
            .tool_use
        else
            .other;
        return .{ .block_start = .{
            .index = indexField(event),
            .kind = block_kind,
            .tool_id = if (block_kind == .tool_use) stringField(block, "id") else null,
            .tool_name = if (block_kind == .tool_use) stringField(block, "name") else null,
        } };
    }
    if (std.mem.eql(u8, kind, "content_block_delta")) {
        const delta = objectField(event, "delta") orelse return .other;
        const delta_type = stringField(delta, "type") orelse return .other;
        if (std.mem.eql(u8, delta_type, "text_delta")) return .{ .text_delta = stringField(delta, "text") orelse "" };
        if (std.mem.eql(u8, delta_type, "thinking_delta")) return .{ .thinking_delta = stringField(delta, "thinking") orelse "" };
        if (std.mem.eql(u8, delta_type, "input_json_delta")) return .{ .input_delta = .{
            .index = indexField(event),
            .partial_json = stringField(delta, "partial_json") orelse "",
        } };
        return .other;
    }
    if (std.mem.eql(u8, kind, "content_block_stop")) return .{ .block_stop = indexField(event) };
    if (std.mem.eql(u8, kind, "message_delta")) {
        const delta = objectField(event, "delta");
        return .{ .message_delta = .{
            .stop_reason = if (delta) |object| stringField(object, "stop_reason") else null,
            .usage = parseCounts(objectField(event, "usage")),
        } };
    }
    if (std.mem.eql(u8, kind, "message_stop")) return .message_stop;
    return .other;
}

fn parseAssistant(arena: Allocator, root: std.json.ObjectMap) !StdoutLine {
    const error_kind = stringField(root, "error");
    const message = objectField(root, "message") orelse return .{ .assistant = .{ .tool_uses = &.{}, .error_kind = error_kind, .text = null } };
    var uses: std.ArrayList(ToolUse) = .empty;
    var text: ?[]const u8 = null;
    if (message.get("content")) |content| if (content == .array) {
        for (content.array.items) |block| {
            if (block != .object) continue;
            const block_type = stringField(block.object, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "text")) {
                text = stringField(block.object, "text");
                continue;
            }
            if (!std.mem.eql(u8, block_type, "tool_use")) continue;
            const id = stringField(block.object, "id") orelse continue;
            const name = stringField(block.object, "name") orelse continue;
            const input = block.object.get("input") orelse std.json.Value{ .object = .empty };
            try uses.append(arena, .{
                .id = id,
                .name = name,
                .input_json = try std.json.Stringify.valueAlloc(arena, input, .{}),
            });
        }
    };
    return .{ .assistant = .{ .tool_uses = uses.items, .error_kind = error_kind, .text = text } };
}

test "claude code: stream events map to step lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = try parseStdoutLine(arena,
        \\{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":1365,"cache_read_input_tokens":10,"output_tokens":1}}},"parent_tool_use_id":null}
    );
    try std.testing.expectEqual(@as(?u64, 1377), start.message_start.usage.usage().input_tokens);
    const text = try parseStdoutLine(arena,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}},"parent_tool_use_id":null}
    );
    try std.testing.expectEqualStrings("hi", text.text_delta);
    const tool = try parseStdoutLine(arena,
        \\{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__fx__read_file","input":{}}},"parent_tool_use_id":null}
    );
    try std.testing.expectEqual(BlockKind.tool_use, tool.block_start.kind);
    try std.testing.expectEqualStrings("toolu_1", tool.block_start.tool_id.?);
    const stop = try parseStdoutLine(arena,
        \\{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":24}}}
    );
    try std.testing.expectEqualStrings("tool_use", stop.message_delta.stop_reason.?);
    try std.testing.expectEqual(@as(?u64, 24), stop.message_delta.usage.output);
    const sub = try parseStdoutLine(arena,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}},"parent_tool_use_id":"toolu_9"}
    );
    try std.testing.expect(sub == .other);
}

test "claude code: assistant messages carry tool input and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = try parseStdoutLine(arena,
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"mcp__fx__echo","input":{"text":"hi"}}]},"parent_tool_use_id":null}
    );
    try std.testing.expectEqual(@as(usize, 1), line.assistant.tool_uses.len);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", line.assistant.tool_uses[0].input_json);
    const failed = try parseStdoutLine(arena,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Not logged in"}]},"error":"authentication_failed"}
    );
    try std.testing.expectEqualStrings("authentication_failed", failed.assistant.error_kind.?);
    const result = try parseStdoutLine(arena,
        \\{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","stop_reason":null,"session_id":"s"}
    );
    try std.testing.expect(result.result.is_error);
    try std.testing.expectEqualStrings("Not logged in · Please run /login", result.result.text.?);
    const limited = try parseStdoutLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794726000}}
    );
    try std.testing.expectEqual(@as(?i64, 1794726000), limited.rate_limited.resets_at);
    const allowed = try parseStdoutLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
    );
    try std.testing.expect(allowed == .other);
    try std.testing.expectError(error.InvalidLine, parseStdoutLine(arena, "not json"));
}

// ---------------------------------------------------------------------------
// The MCP bridge

pub const McpIncoming = union(enum) {
    initialize: struct { id_json: []const u8, protocol_version: ?[]const u8 },
    tools_list: []const u8,
    tools_call: McpCall,
    ping: []const u8,
    /// `notifications/cancelled`: the request id Claude Code gave up on.
    cancelled: ?[]const u8,
    /// A request fx doesn't serve; it gets method-not-found.
    unknown_request: []const u8,
    /// A notification or response fx ignores.
    ignored,
};

pub const McpCall = struct {
    /// The JSON-RPC id exactly as Claude Code sent it, serialized.
    id_json: []const u8,
    /// Claude's tool-use id, from `_meta`.
    tool_use_id: ?[]const u8,
    name: []const u8,
    arguments_json: []const u8,
};

/// Parses one JSON-RPC line from Claude Code.
pub fn parseMcpLine(arena: Allocator, line: []const u8) !McpIncoming {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidLine,
    };
    if (value != .object) return error.InvalidLine;
    const root = value.object;
    const method = stringField(root, "method") orelse return .ignored;
    const id = root.get("id");
    const id_json: ?[]const u8 = if (id) |raw| try std.json.Stringify.valueAlloc(arena, raw, .{}) else null;
    const params = objectField(root, "params");
    if (id_json == null) {
        if (std.mem.eql(u8, method, "notifications/cancelled")) {
            const request_id = if (params) |object| object.get("requestId") else null;
            return .{ .cancelled = if (request_id) |raw| try std.json.Stringify.valueAlloc(arena, raw, .{}) else null };
        }
        return .ignored;
    }
    if (std.mem.eql(u8, method, "initialize")) {
        return .{ .initialize = .{
            .id_json = id_json.?,
            .protocol_version = if (params) |object| stringField(object, "protocolVersion") else null,
        } };
    }
    if (std.mem.eql(u8, method, "tools/list")) return .{ .tools_list = id_json.? };
    if (std.mem.eql(u8, method, "ping")) return .{ .ping = id_json.? };
    if (std.mem.eql(u8, method, "tools/call")) {
        const object = params orelse return .{ .unknown_request = id_json.? };
        const name = stringField(object, "name") orelse return .{ .unknown_request = id_json.? };
        const arguments = object.get("arguments") orelse std.json.Value{ .object = .empty };
        const meta = objectField(object, "_meta");
        return .{ .tools_call = .{
            .id_json = id_json.?,
            .tool_use_id = if (meta) |fields| stringField(fields, "claudecode/toolUseId") else null,
            .name = name,
            .arguments_json = try std.json.Stringify.valueAlloc(arena, arguments, .{}),
        } };
    }
    return .{ .unknown_request = id_json.? };
}

/// Protocol versions fx answers `initialize` with, newest first. A client
/// that asks for one of these gets it back.
const supported_protocol_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

pub fn writeInitializeResult(writer: *Writer, id_json: []const u8, requested: ?[]const u8) !void {
    var version: []const u8 = supported_protocol_versions[0];
    if (requested) |asked| for (supported_protocol_versions) |candidate| {
        if (std.mem.eql(u8, candidate, asked)) version = candidate;
    };
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":", .{id_json});
    try std.json.Stringify.value(version, .{}, writer);
    try writer.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"fx\",\"version\":\"1\"}}}\n");
}

pub fn writeResult(writer: *Writer, id_json: []const u8, result_json: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_json, result_json });
}

pub fn writeMethodNotFound(writer: *Writer, id_json: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}\n", .{id_json});
}

pub fn writeToolsChanged(writer: *Writer) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n");
}

/// The answer to one `tools/call`: fx's tool result as text.
pub fn writeToolCallResult(writer: *Writer, id_json: []const u8, text: []const u8, is_error: bool) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{id_json});
    try std.json.Stringify.value(if (text.len == 0) "(no output)" else text, .{}, writer);
    try writer.print("}}],\"isError\":{s}}}}}\n", .{if (is_error) "true" else "false"});
}

test "claude code: MCP requests parse with their raw ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const init = try parseMcpLine(arena,
        \\{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}},"jsonrpc":"2.0","id":0}
    );
    try std.testing.expectEqualStrings("0", init.initialize.id_json);
    const probe = try parseMcpLine(arena,
        \\{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{}}
    );
    try std.testing.expectEqualStrings("\"server-discover-probe-1\"", probe.unknown_request);
    const call = try parseMcpLine(arena,
        \\{"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},"_meta":{"claudecode/toolUseId":"toolu_01","progressToken":2}},"jsonrpc":"2.0","id":2}
    );
    try std.testing.expectEqualStrings("2", call.tools_call.id_json);
    try std.testing.expectEqualStrings("toolu_01", call.tools_call.tool_use_id.?);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", call.tools_call.arguments_json);
    const cancel = try parseMcpLine(arena,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}
    );
    try std.testing.expectEqualStrings("2", cancel.cancelled.?);
    try std.testing.expect((try parseMcpLine(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == .ignored);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeInitializeResult(&out.writer, "0", "2025-06-18");
    try writeToolCallResult(&out.writer, "2", "echo:hi", false);
    try writeMethodNotFound(&out.writer, "\"p\"");
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{\"listChanged\":true}},\"serverInfo\":{\"name\":\"fx\",\"version\":\"1\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo:hi\"}],\"isError\":false}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":\"p\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n",
        out.written(),
    );
}

// ---------------------------------------------------------------------------
// History alignment

/// The part of one history entry both fx and Claude Code must agree on.
pub const Unit = struct {
    kind: Kind,
    /// The text's hash for `user`; the id's hash for `call` and `result`.
    hash: u64,
    /// The message the unit came from, in the history it was taken from.
    message_index: usize,

    pub const Kind = enum(u8) { user, call, result };

    pub fn same(self: Unit, other: Unit) bool {
        return self.kind == other.kind and self.hash == other.hash;
    }
};

/// The hash units use for text and ids.
pub fn hashText(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

/// The units of `messages`. Assistant text is left out: fx may tidy what it
/// keeps, and Claude Code's copy is the one the model sees. System messages
/// in the history, such as context notes, count as user text, since that is
/// how they reach Claude Code.
pub fn units(alloc: Allocator, messages: []const types.ChatMessage) ![]Unit {
    var out: std.ArrayList(Unit) = .empty;
    errdefer out.deinit(alloc);
    for (messages, 0..) |message, index| switch (message.role) {
        .user, .system => try out.append(alloc, .{ .kind = .user, .hash = hashText(message.content orelse ""), .message_index = index }),
        .assistant => for (message.tool_calls) |call| {
            try out.append(alloc, .{ .kind = .call, .hash = hashText(call.id), .message_index = index });
        },
        .tool => try out.append(alloc, .{ .kind = .result, .hash = hashText(message.tool_call_id orelse ""), .message_index = index }),
    };
    return out.toOwnedSlice(alloc);
}

/// A digest of `list`, saved with a reply so a later fx process can tell
/// whether a history still starts with what Claude Code saw.
pub fn digest(list: []const Unit) u64 {
    var hasher = std.hash.Wyhash.init(0x6678);
    for (list) |unit| {
        hasher.update(&.{@backingInt(unit.kind)});
        hasher.update(std.mem.asBytes(&unit.hash));
    }
    return hasher.final();
}

pub const DeltaPlan = union(enum) {
    /// The request extends what the process has. `first` is the index of
    /// the first new unit; results for every pending call come first, then
    /// `user_from` (when set) starts the user text to send.
    extend: struct { first: usize, results_end: usize, missing_results: usize },
    /// The request does not extend what the process has.
    diverged: Divergence,
};

pub const Divergence = enum {
    /// The request drops or changes an entry the process already has.
    rewritten,
    /// The request answers fewer calls than are pending, or asks again with
    /// nothing new.
    out_of_order,
    /// The request holds a tool call the process never made.
    foreign_call,
};

/// Compares a request's units with the ones the process has seen.
/// `pending` holds the hashes of calls the process waits on: the new units
/// must answer them before anything else. Results it leaves out are
/// counted in `missing_results`; the caller answers those as not run.
pub fn planDelta(seen: []const Unit, request: []const Unit, pending: []const u64) DeltaPlan {
    if (request.len < seen.len) return .{ .diverged = .rewritten };
    for (seen, request[0..seen.len]) |old, new| {
        if (!old.same(new)) return .{ .diverged = .rewritten };
    }
    var index = seen.len;
    var answered: usize = 0;
    while (index < request.len and request[index].kind == .result) : (index += 1) {
        var found = false;
        for (pending) |hash| if (hash == request[index].hash) {
            found = true;
        };
        if (!found) return .{ .diverged = .out_of_order };
        answered += 1;
    }
    const results_end = index;
    var user_text = false;
    while (index < request.len) : (index += 1) switch (request[index].kind) {
        .user => user_text = true,
        .call => return .{ .diverged = .foreign_call },
        .result => return .{ .diverged = .out_of_order },
    };
    // Nothing new at all: a repeated request that Claude Code has no way to
    // answer again from where it stands.
    if (answered == 0 and !user_text) return .{ .diverged = .out_of_order };
    return .{ .extend = .{ .first = seen.len, .results_end = results_end, .missing_results = pending.len - answered } };
}

fn testUnits(comptime spec: []const u8) [spec.len]Unit {
    var out: [spec.len]Unit = undefined;
    for (spec, 0..) |char, index| {
        out[index] = switch (char) {
            'u' => .{ .kind = .user, .hash = 1, .message_index = index },
            'v' => .{ .kind = .user, .hash = 2, .message_index = index },
            'a' => .{ .kind = .call, .hash = 10, .message_index = index },
            'b' => .{ .kind = .call, .hash = 11, .message_index = index },
            'A' => .{ .kind = .result, .hash = 10, .message_index = index },
            'B' => .{ .kind = .result, .hash = 11, .message_index = index },
            else => unreachable,
        };
    }
    return out;
}

test "claude code: a request that extends the process's history is sent as its new part" {
    const seen = testUnits("uab");
    const request = testUnits("uabBAv");
    const plan = planDelta(&seen, &request, &.{ 10, 11 });
    try std.testing.expectEqual(@as(usize, 3), plan.extend.first);
    try std.testing.expectEqual(@as(usize, 5), plan.extend.results_end);
    try std.testing.expectEqual(@as(usize, 0), plan.extend.missing_results);

    const next_turn = testUnits("uv");
    try std.testing.expectEqual(@as(usize, 1), planDelta(next_turn[0..1], &next_turn, &.{}).extend.first);
}

test "claude code: a request that answers some calls counts the rest as not run" {
    const seen = testUnits("uab");
    const request = testUnits("uabAv");
    const plan = planDelta(&seen, &request, &.{ 10, 11 });
    try std.testing.expectEqual(@as(usize, 1), plan.extend.missing_results);
    const dropped = testUnits("uabv");
    try std.testing.expectEqual(@as(usize, 2), planDelta(&seen, &dropped, &.{ 10, 11 }).extend.missing_results);
}

test "claude code: a rewritten, repeated, or foreign history diverges" {
    const seen = testUnits("uabAB");
    try std.testing.expectEqual(Divergence.rewritten, planDelta(&seen, &testUnits("v"), &.{}).diverged);
    try std.testing.expectEqual(Divergence.rewritten, planDelta(&seen, &testUnits("uaAv"), &.{}).diverged);
    try std.testing.expectEqual(Divergence.out_of_order, planDelta(&seen, &seen, &.{}).diverged);
    try std.testing.expectEqual(Divergence.foreign_call, planDelta(&seen, &testUnits("uabABva"), &.{}).diverged);
    const waiting = testUnits("ua");
    try std.testing.expectEqual(Divergence.out_of_order, planDelta(&waiting, &testUnits("uaB"), &.{10}).diverged);
}

test "claude code: units follow user text, call ids, and result ids" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "looking", .tool_calls = &.{
            .{ .id = "toolu_1", .name = "read_file", .arguments_json = "{}" },
            .{ .id = "toolu_2", .name = "read_file", .arguments_json = "{}" },
        } },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "one" },
        .{ .role = .tool, .tool_call_id = "toolu_2", .content = "two" },
        .{ .role = .assistant, .content = "done" },
    };
    const list = try units(alloc, &messages);
    defer alloc.free(list);
    try std.testing.expectEqual(@as(usize, 5), list.len);
    try std.testing.expectEqual(Unit.Kind.call, list[2].kind);
    try std.testing.expectEqual(@as(usize, 1), list[2].message_index);
    try std.testing.expect(list[1].same(.{ .kind = .call, .hash = hashText("toolu_1"), .message_index = 0 }));
    const edited = [_]types.ChatMessage{ messages[0], messages[1], messages[2], messages[3], .{ .role = .assistant, .content = "done, tidied" } };
    const again = try units(alloc, &edited);
    defer alloc.free(again);
    try std.testing.expectEqual(digest(list), digest(again));
}

// ---------------------------------------------------------------------------
// Text fx sends as a user message

/// Joins the user text of `messages` into one message.
pub fn writeUserText(writer: *Writer, messages: []const types.ChatMessage) !void {
    var first = true;
    for (messages) |message| {
        if (message.role != .user and message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (!first) try writer.writeAll("\n\n");
        first = false;
        if (message.role == .system) {
            try writer.writeAll("<system-note>\n");
            try writer.writeAll(text);
            try writer.writeAll("\n</system-note>");
        } else try writer.writeAll(text);
    }
}

/// Writes `messages` as a plain transcript, for a new Claude Code session
/// that must pick up a conversation it never saw.
pub fn writeTranscript(writer: *Writer, messages: []const types.ChatMessage) !void {
    for (messages) |message| {
        switch (message.role) {
            .system => {
                try writer.writeAll("[system note]\n");
                try writer.writeAll(message.content orelse "");
            },
            .user => {
                try writer.writeAll("[user]\n");
                try writer.writeAll(message.content orelse "");
            },
            .assistant => {
                try writer.writeAll("[assistant]");
                if (message.content) |text| if (text.len > 0) {
                    try writer.writeByte('\n');
                    try writer.writeAll(text);
                };
                for (message.tool_calls) |call| {
                    try writer.print("\n[tool call {s} id={s}] ", .{ call.name, call.id });
                    try writer.writeAll(call.arguments_json);
                }
            },
            .tool => {
                try writer.print("[tool result {s} id={s}{s}]\n", .{
                    message.tool_name orelse "tool",
                    message.tool_call_id orelse "",
                    if (message.tool_result_status == .failure) " failed" else "",
                });
                try writer.writeAll(message.content orelse "");
            },
        }
        try writer.writeAll("\n\n");
    }
}

/// The first message of a new Claude Code session for a conversation that
/// already has history: the history as a transcript, then what is new.
pub fn writeSeededPrompt(alloc: Allocator, writer: *Writer, history: []const types.ChatMessage, latest: []const types.ChatMessage) !void {
    try writer.writeAll(
        "<conversation_so_far>\nThis conversation started before this session. Its history so far follows, " ++
            "with each tool call and its result. Treat it as your own earlier work and continue from it; " ++
            "don't repeat tool calls whose results are shown.\n\n",
    );
    try writeTranscript(writer, history);
    try writer.writeAll("</conversation_so_far>\n\n");
    var latest_text: std.Io.Writer.Allocating = .init(alloc);
    defer latest_text.deinit();
    try writeUserText(&latest_text.writer, latest);
    if (latest_text.written().len > 0) {
        try writer.writeAll(latest_text.written());
    } else {
        try writer.writeAll("Continue from the last tool results above.");
    }
}

test "claude code: a seeded prompt carries the transcript and the new request" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const history = [_]types.ChatMessage{
        .{ .role = .user, .content = "read a.txt" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c1", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" }} },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "read_file", .content = "alpha" },
        .{ .role = .assistant, .content = "It says alpha." },
    };
    const latest = [_]types.ChatMessage{.{ .role = .user, .content = "and b.txt?" }};
    try writeSeededPrompt(std.testing.allocator, &out.writer, &history, &latest);
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "[tool call read_file id=c1] {\"path\":\"a.txt\"}") != null);
    try std.testing.expect(std.mem.find(u8, text, "[tool result read_file id=c1]\nalpha") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "and b.txt?"));
}

// ---------------------------------------------------------------------------
// Replay: what a reply records so a later fx process can resume the session

pub const Replay = struct {
    session_id: []const u8,
    /// How many units of the history Claude Code had seen, and their digest.
    units: usize,
    digest: u64,
};

pub fn writeReplay(alloc: Allocator, replay: Replay) ![]u8 {
    var digest_hex: [16]u8 = undefined;
    _ = std.mem.print(&digest_hex, "{x:0>16}", .{replay.digest}) catch unreachable;
    return alloc.print("{{\"claude_code\":{{\"session\":\"{s}\",\"units\":{d},\"digest\":\"{s}\"}}}}", .{ replay.session_id, replay.units, &digest_hex });
}

/// Reads a reply's replay record. Null when it isn't one of fx's, or is
/// malformed. `session_id` borrows `arena`.
pub fn parseReplay(arena: Allocator, parts_json: []const u8) ?Replay {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, parts_json, .{}) catch return null;
    if (value != .object) return null;
    const record = objectField(value.object, "claude_code") orelse return null;
    const session_id = stringField(record, "session") orelse return null;
    if (!validSessionId(session_id)) return null;
    const count = countField(record, "units") orelse return null;
    const digest_hex = stringField(record, "digest") orelse return null;
    if (digest_hex.len != 16) return null;
    const parsed = std.fmt.parseInt(u64, digest_hex, 16) catch return null;
    return .{ .session_id = session_id, .units = @intCast(count), .digest = parsed };
}

/// A lowercase UUID, the only session id fx passes to `claude`.
pub fn validSessionId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |char, index| {
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    }
    return true;
}

/// Formats 16 random bytes as a version 4 UUID.
pub fn formatSessionId(bytes: [16]u8) [36]u8 {
    var value = bytes;
    value[6] = (value[6] & 0x0f) | 0x40;
    value[8] = (value[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(value, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

test "claude code: replay records round-trip and reject other providers' parts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = formatSessionId(@splat(0xab));
    try std.testing.expect(validSessionId(&id));
    const json = try writeReplay(arena, .{ .session_id = &id, .units = 7, .digest = 0x1234 });
    const parsed = parseReplay(arena, json).?;
    try std.testing.expectEqualStrings(&id, parsed.session_id);
    try std.testing.expectEqual(@as(usize, 7), parsed.units);
    try std.testing.expectEqual(@as(u64, 0x1234), parsed.digest);
    try std.testing.expect(parseReplay(arena, "[{\"type\":\"reasoning\"}]") == null);
    try std.testing.expect(parseReplay(arena, "{\"claude_code\":{\"session\":\"../x\",\"units\":1,\"digest\":\"0000000000000000\"}}") == null);
}

// ---------------------------------------------------------------------------
// Failures

pub const FailureClass = enum {
    not_signed_in,
    usage_limit,
    billing,
    invalid_request,
    overloaded,
    other,
};

/// Classifies the `error` an `assistant` message reports, or a failed
/// result's text when Claude Code sent no error kind.
pub fn classifyFailure(error_kind: ?[]const u8, text: ?[]const u8) FailureClass {
    if (error_kind) |kind| {
        if (std.mem.eql(u8, kind, "authentication_failed")) return .not_signed_in;
        if (std.mem.eql(u8, kind, "rate_limit")) return .usage_limit;
        if (std.mem.eql(u8, kind, "billing_error")) return .billing;
        if (std.mem.eql(u8, kind, "invalid_request")) return .invalid_request;
        if (std.mem.eql(u8, kind, "server_error") or std.mem.eql(u8, kind, "overloaded")) return .overloaded;
    }
    const detail = text orelse return .other;
    if (std.mem.find(u8, detail, "Not logged in") != null or std.mem.find(u8, detail, "/login") != null) return .not_signed_in;
    if (std.mem.find(u8, detail, "hit your limit") != null or std.mem.find(u8, detail, "usage limit") != null) return .usage_limit;
    return .other;
}

test "claude code: failures are classified from the error kind first" {
    try std.testing.expectEqual(FailureClass.not_signed_in, classifyFailure("authentication_failed", null));
    try std.testing.expectEqual(FailureClass.not_signed_in, classifyFailure(null, "Not logged in · Please run /login"));
    try std.testing.expectEqual(FailureClass.usage_limit, classifyFailure("rate_limit", "anything"));
    try std.testing.expectEqual(FailureClass.usage_limit, classifyFailure(null, "You've hit your limit · resets 5pm"));
    try std.testing.expectEqual(FailureClass.other, classifyFailure("unknown", "boom"));
}
