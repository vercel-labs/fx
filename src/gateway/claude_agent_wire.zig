//! The pure half of the `anthropic` provider's Claude Code mode (D165-D167).
//!
//! Inbound, a Messages request body (built by the Messages codec, so
//! history, thinking replay and tool results project exactly as on the API)
//! becomes what the `claude` executable reads: a system prompt file, the MCP
//! tool list a stub serves, a session transcript seeded with every message
//! but the last, and the last user message as one stream-json line. A
//! trailing tool result stays in the transcript and the prompt becomes
//! proto's "continue" line, because Claude repairs dangling tool uses while
//! it loads a transcript.
//!
//! Outbound, each stream-json line is unwrapped: a `stream_event` carries
//! the raw Messages SSE event, which goes to the Messages reducer with the
//! MCP prefix taken off tool names; failures Claude reports in its own
//! messages become provider failures.
const std = @import("std");
const streams = @import("../core/agent/stream_provider.zig");
const Allocator = std.mem.Allocator;

/// MCP server name in `--mcp-config`; Claude names its tools
/// `mcp__<server>__<tool>`.
pub const server_name = "proto_fx";
pub const tool_prefix = "mcp__" ++ server_name ++ "__";
/// Proto's claude-agent-continue.md.
pub const continue_prompt = "Continue from the tool results above.";

pub const Error = Allocator.Error || error{ InvalidProviderPrompt, WriteFailed };

pub const Ids = struct {
    /// The Claude session id, a UUID.
    session: []const u8,
    cwd: []const u8,
    model: []const u8,
    /// ISO 8601 time stamped on seeded entries.
    timestamp: []const u8,
};

/// Everything the executable is handed. Owned; free with deinit.
pub const Prepared = struct {
    system: []u8,
    /// JSON array of MCP tool definitions; `[]` when the request has none.
    tools_json: []u8,
    tool_count: usize,
    /// JSONL session transcript; empty when there is no earlier history.
    transcript: []u8,
    /// One stream-json user message, newline terminated.
    prompt_line: []u8,
    continues_tools: bool,

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        alloc.free(self.system);
        alloc.free(self.tools_json);
        alloc.free(self.transcript);
        alloc.free(self.prompt_line);
        self.* = undefined;
    }
};

/// A UUID-shaped id derived from `seed`, so a session keeps its Claude
/// session id across requests and seeded entries are reproducible.
pub fn derivedUuid(seed: []const u8, index: usize) [36]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("proto-fx-claude-uuid");
    hash.update(seed);
    var index_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &index_bytes, index, .little);
    hash.update(&index_bytes);
    var digest = hash.finalResult();
    digest[6] = (digest[6] & 0x0f) | 0x40;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var at: usize = 0;
    for (digest[0..16], 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[at] = '-';
            at += 1;
        }
        out[at] = hex[byte >> 4];
        out[at + 1] = hex[byte & 0x0f];
        at += 2;
    }
    return out;
}

/// Splits a Messages request body into what Claude reads.
pub fn prepare(alloc: Allocator, body: []const u8, ids: Ids) Error!Prepared {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidProviderPrompt;
    if (root != .object) return error.InvalidProviderPrompt;
    // Claude Code places its own cache breakpoints, at most four in all.
    stripCacheControl(&root);

    var system: std.ArrayList(u8) = .empty;
    if (root.object.get("system")) |blocks| {
        if (blocks != .array) return error.InvalidProviderPrompt;
        for (blocks.array.items) |block| {
            const text = textOf(block) orelse continue;
            if (system.items.len != 0) try system.appendSlice(arena, "\n\n");
            try system.appendSlice(arena, text);
        }
    }

    var tools: std.Io.Writer.Allocating = .init(arena);
    var tool_count: usize = 0;
    try tools.writer.writeByte('[');
    if (root.object.get("tools")) |list| {
        if (list != .array) return error.InvalidProviderPrompt;
        for (list.array.items) |tool| {
            if (tool != .object) return error.InvalidProviderPrompt;
            const name = tool.object.get("name") orelse return error.InvalidProviderPrompt;
            if (name != .string) return error.InvalidProviderPrompt;
            if (tool_count != 0) try tools.writer.writeByte(',');
            try tools.writer.writeAll("{\"name\":");
            try std.json.Stringify.value(name.string, .{}, &tools.writer);
            try tools.writer.writeAll(",\"description\":");
            const description = tool.object.get("description") orelse std.json.Value{ .string = "" };
            try std.json.Stringify.value(description, .{}, &tools.writer);
            try tools.writer.writeAll(",\"inputSchema\":");
            const schema = tool.object.get("input_schema") orelse std.json.Value{ .object = .empty };
            try std.json.Stringify.value(schema, .{}, &tools.writer);
            // Claude defers MCP tools behind tool search unless told to load them.
            try tools.writer.writeAll(",\"_meta\":{\"anthropic/alwaysLoad\":true}}");
            tool_count += 1;
        }
    }
    try tools.writer.writeByte(']');

    const messages_value = root.object.get("messages") orelse return error.InvalidProviderPrompt;
    if (messages_value != .array or messages_value.array.items.len == 0) return error.InvalidProviderPrompt;
    var messages = messages_value.array.items;
    for (messages) |message| try prefixToolNames(arena, message);
    const last = messages[messages.len - 1];
    if (!isRole(last, "user")) return error.InvalidProviderPrompt;
    const continues_tools = hasToolResult(last);
    const prompt_content: std.json.Value = if (continues_tools) .{ .string = continue_prompt } else last.object.get("content").?;
    if (!continues_tools) messages = messages[0 .. messages.len - 1];

    var transcript: std.Io.Writer.Allocating = .init(arena);
    var parent: ?[36]u8 = null;
    for (messages, 0..) |message, index| {
        const uuid = derivedUuid(ids.session, index);
        const assistant = isRole(message, "assistant");
        var entry = message;
        if (assistant) {
            // Claude reads an assistant entry as a complete API message.
            var object = try message.object.clone(arena);
            const id = try std.mem.concat(arena, u8, &.{ "msg_", &uuid });
            try object.put(arena, "id", .{ .string = id });
            try object.put(arena, "type", .{ .string = "message" });
            try object.put(arena, "model", .{ .string = ids.model });
            try object.put(arena, "stop_reason", .{ .string = if (hasBlock(message, "tool_use")) "tool_use" else "end_turn" });
            try object.put(arena, "stop_sequence", .null);
            var usage: std.json.ObjectMap = .empty;
            try usage.put(arena, "input_tokens", .{ .integer = 0 });
            try usage.put(arena, "output_tokens", .{ .integer = 0 });
            try object.put(arena, "usage", .{ .object = usage });
            entry = .{ .object = object };
        }
        const w = &transcript.writer;
        try w.writeAll("{\"parentUuid\":");
        if (parent) |value| try std.json.Stringify.value(@as([]const u8, &value), .{}, w) else try w.writeAll("null");
        try w.writeAll(",\"isSidechain\":false,\"type\":");
        try w.writeAll(if (assistant) "\"assistant\"" else "\"user\"");
        try w.writeAll(",\"message\":");
        try std.json.Stringify.value(entry, .{}, w);
        try w.print(",\"uuid\":\"{s}\",\"timestamp\":", .{&uuid});
        try std.json.Stringify.value(ids.timestamp, .{}, w);
        try w.writeAll(",\"userType\":\"external\",\"cwd\":");
        try std.json.Stringify.value(ids.cwd, .{}, w);
        try w.writeAll(",\"sessionId\":");
        try std.json.Stringify.value(ids.session, .{}, w);
        try w.writeAll("}\n");
        parent = uuid;
    }

    var prompt: std.Io.Writer.Allocating = .init(arena);
    try prompt.writer.writeAll("{\"type\":\"user\",\"session_id\":");
    try std.json.Stringify.value(ids.session, .{}, &prompt.writer);
    try prompt.writer.writeAll(",\"parent_tool_use_id\":null,\"message\":{\"role\":\"user\",\"content\":");
    try std.json.Stringify.value(prompt_content, .{}, &prompt.writer);
    try prompt.writer.writeAll("}}\n");

    const owned_system = try alloc.dupe(u8, system.items);
    errdefer alloc.free(owned_system);
    const owned_tools = try alloc.dupe(u8, tools.written());
    errdefer alloc.free(owned_tools);
    const owned_transcript = try alloc.dupe(u8, transcript.written());
    errdefer alloc.free(owned_transcript);
    return .{
        .system = owned_system,
        .tools_json = owned_tools,
        .tool_count = tool_count,
        .transcript = owned_transcript,
        .prompt_line = try alloc.dupe(u8, prompt.written()),
        .continues_tools = continues_tools,
    };
}

fn stripCacheControl(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            _ = object.orderedRemove("cache_control");
            for (object.values()) |*child| stripCacheControl(child);
        },
        .array => |*array| for (array.items) |*child| stripCacheControl(child),
        else => {},
    }
}

fn textOf(block: std.json.Value) ?[]const u8 {
    if (block != .object) return null;
    const text = block.object.get("text") orelse return null;
    return if (text == .string) text.string else null;
}

fn isRole(message: std.json.Value, role: []const u8) bool {
    if (message != .object) return false;
    const value = message.object.get("role") orelse return false;
    return value == .string and std.mem.eql(u8, value.string, role);
}

fn hasBlock(message: std.json.Value, kind: []const u8) bool {
    const content = message.object.get("content") orelse return false;
    if (content != .array) return false;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const value = block.object.get("type") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, kind)) return true;
    }
    return false;
}

fn hasToolResult(message: std.json.Value) bool {
    return hasBlock(message, "tool_result");
}

fn prefixToolNames(arena: Allocator, message: std.json.Value) Error!void {
    if (message != .object) return error.InvalidProviderPrompt;
    const content = message.object.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |*block| {
        if (block.* != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "tool_use")) continue;
        const name = block.object.getPtr("name") orelse continue;
        if (name.* != .string) return error.InvalidProviderPrompt;
        name.* = .{ .string = try std.mem.concat(arena, u8, &.{ tool_prefix, name.string }) };
    }
}

/// What one stream-json line means for the request.
pub const Line = union(enum) {
    /// Nothing for proto-fx: init, status, hook, subagent or SDK-side events.
    ignore,
    /// A Messages SSE event for the reducer, prefix stripped. Owned.
    event: []u8,
    /// Claude reported a failure. Owned detail.
    failure: struct { kind: streams.FailureKind, detail: []u8 },
    /// The run's result line: nothing more follows.
    result,
};

/// Unwraps one stream-json line. Caller owns what the result carries.
pub fn unwrap(alloc: Allocator, raw: []const u8) Error!Line {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .ignore;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Claude writes diagnostics on stdout only by mistake; skip them.
        else => return .ignore,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .ignore;
    const root = parsed.value.object;
    const kind = stringField(root, "type") orelse return .ignore;
    if (std.mem.eql(u8, kind, "stream_event")) {
        // Events of a subagent turn belong to Claude's own tool runs.
        if (root.get("parent_tool_use_id")) |parent| if (parent != .null) return .ignore;
        var event = root.get("event") orelse return .ignore;
        if (event != .object) return .ignore;
        if (event.object.get("content_block")) |block| if (block == .object) {
            if (block.object.getPtr("name")) |name| if (name.* == .string and std.mem.startsWith(u8, name.string, tool_prefix)) {
                name.* = .{ .string = name.string[tool_prefix.len..] };
            };
        };
        return .{ .event = try std.json.Stringify.valueAlloc(alloc, event, .{}) };
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        const code = stringField(root, "error") orelse return .ignore;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);
        if (root.get("message")) |message| if (message == .object) if (message.object.get("content")) |content| if (content == .array) {
            for (content.array.items) |block| if (textOf(block)) |value| {
                if (text.items.len != 0) try text.append(alloc, '\n');
                try text.appendSlice(alloc, value);
            };
        };
        return .{ .failure = .{ .kind = errorKind(code), .detail = try alloc.dupe(u8, if (text.items.len != 0) text.items else code) } };
    }
    if (std.mem.eql(u8, kind, "system")) {
        const subtype = stringField(root, "subtype") orelse return .ignore;
        if (!std.mem.eql(u8, subtype, "api_retry")) return .ignore;
        const status_value = root.get("error_status") orelse return .ignore;
        const status = numberOf(status_value) orelse return .ignore;
        // Client errors other than timeouts and conflicts will not heal by
        // retrying the same request; the runtime owns retries and rotation.
        if (status < 400 or status >= 500 or status == 408 or status == 409) return .ignore;
        const detail = try alloc.print("{d} {s}", .{ status, stringField(root, "error") orelse "Claude API error" });
        return .{ .failure = .{ .kind = statusKind(status), .detail = detail } };
    }
    if (std.mem.eql(u8, kind, "result")) {
        const is_error = root.get("is_error") orelse return .result;
        if (is_error != .bool or !is_error.bool) return .result;
        var detail: std.ArrayList(u8) = .empty;
        defer detail.deinit(alloc);
        if (stringField(root, "result")) |text| try detail.appendSlice(alloc, text);
        if (root.get("errors")) |errors| if (errors == .array) for (errors.array.items) |item| if (item == .string) {
            if (detail.items.len != 0) try detail.append(alloc, '\n');
            try detail.appendSlice(alloc, item.string);
        };
        if (detail.items.len == 0) try detail.appendSlice(alloc, stringField(root, "subtype") orelse "Claude Code failed");
        return .{ .failure = .{ .kind = .provider_error, .detail = try detail.toOwnedSlice(alloc) } };
    }
    return .ignore;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn numberOf(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |n| std.math.cast(u32, n),
        .number_string => |text| std.fmt.parseInt(u32, text, 10) catch null,
        else => null,
    };
}

/// Proto's mapping of Claude's assistant error codes to HTTP statuses.
fn errorKind(code: []const u8) streams.FailureKind {
    const table = [_]struct { []const u8, streams.FailureKind }{
        .{ "authentication_failed", .unauthorized }, .{ "oauth_org_not_allowed", .forbidden },
        .{ "account_on_hold", .forbidden },          .{ "verification_required", .forbidden },
        .{ "billing_error", .forbidden },            .{ "rate_limit", .rate_limited },
        .{ "overloaded", .unavailable },             .{ "invalid_request", .invalid_request },
        .{ "server_error", .server_error },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], code)) return entry[1];
    return .provider_error;
}

fn statusKind(status: u32) streams.FailureKind {
    return switch (status) {
        400 => .invalid_request,
        401 => .unauthorized,
        403 => .forbidden,
        413 => .request_too_large,
        429 => .rate_limited,
        else => .provider_error,
    };
}

test {
    _ = @import("claude_agent_tests.zig");
}
