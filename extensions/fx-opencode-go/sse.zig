//! Completed chat state owns its buffers until the host receives a terminal reply.
const std = @import("std");
const wire = @import("wire.zig");
const Allocator = wire.Allocator;
const Value = wire.Value;
const event_method = "extension.event";
const max_event_bytes = 1024 * 1024;
const max_text_bytes = 1024 * 1024;
const max_delta_bytes = 64 * 1024;
const max_tool_calls = 128;
const max_identity_bytes = 1024;
const data_prefix = "data:";
const done_marker = "[DONE]";
const terminal_delete_byte = 0x7f;
const utf8_tag_mask = 0xc0;
const utf8_continuation_tag = 0x80;

const Call = struct { id: []const u8 = "", name: []const u8 = "", arguments: std.ArrayList(u8) = .empty };

/// All events carry the host's stream request identity, never a provider-generated identifier.
pub const Context = struct {
    alloc: Allocator,
    output: *wire.Output,
    id: u64,
    handle: []const u8,
    cancel: *std.atomic.Value(bool),
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    reasoning_seen: bool = false,
    calls: std.ArrayList(Call) = .empty,
    finish: ?[]const u8 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,

    /// The worker releases accumulator storage only after serializing the final reply.
    pub fn deinit(self: *Context) void {
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        for (self.calls.items) |*call| {
            if (call.id.len > 0) self.alloc.free(call.id);
            if (call.name.len > 0) self.alloc.free(call.name);
            call.arguments.deinit(self.alloc);
        }
        self.calls.deinit(self.alloc);
    }

    /// Event and total-text bounds stop oversized responses before transcript publication.
    pub fn consume(self: *Context, reader: *std.Io.Reader) !void {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.alloc);
        var done = false;
        while (try wire.read_line(self.alloc, reader)) |line| {
            defer self.alloc.free(line);
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) {
                if (data.items.len == 0) continue;
                if (std.mem.eql(u8, data.items, done_marker)) {
                    done = true;
                    break;
                }
                try self.chunk(data.items);
                data.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, trimmed, data_prefix)) {
                const value = std.mem.trimStart(u8, trimmed[data_prefix.len..], " ");
                if (value.len >= max_event_bytes - data.items.len) return error.ResponseTooLarge;
                if (data.items.len > 0) try data.append(self.alloc, '\n');
                try data.appendSlice(self.alloc, value);
            }
        }
        if (!done or self.finish == null) return error.IncompleteResponse;
    }

    /// Provider errors remain opaque instead of becoming assistant text or retryable completions.
    fn chunk(self: *Context, bytes: []const u8) !void {
        var parsed = try std.json.parseFromSlice(Value, self.alloc, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object or root.object.contains("error")) return error.ProviderFailed;
        if (root.object.get("usage")) |usage| if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |value| self.input_tokens = try token_count(value);
            if (usage.object.get("completion_tokens")) |value| self.output_tokens = try token_count(value);
        };
        const choices = root.object.get("choices") orelse return error.InvalidResponse;
        if (choices != .array or choices.array.items.len > 1) return error.InvalidResponse;
        if (choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return error.InvalidResponse;
        if (choice.object.get("finish_reason")) |value| if (value != .null) {
            const reason = try wire.text(value);
            if (std.mem.eql(u8, reason, "stop")) self.finish = "stop" else if (std.mem.eql(u8, reason, "tool_calls")) self.finish = "tool_calls" else if (std.mem.eql(u8, reason, "length")) self.finish = "length" else if (std.mem.eql(u8, reason, "content_filter")) self.finish = "content_filter" else return error.InvalidResponse;
        };
        const delta = try wire.field(choice, "delta");
        if (delta != .object) return error.InvalidResponse;
        if (delta.object.get("content")) |value| if (value != .null) {
            const text = try wire.text(value);
            try append_bounded(self.alloc, &self.content, text);
            try self.emit_text("content_delta", text);
        };
        if (delta.object.get("reasoning_content")) |value| if (value != .null) {
            const text = try wire.text(value);
            self.reasoning_seen = true;
            try append_bounded(self.alloc, &self.reasoning, text);
            try self.emit_text("reasoning_delta", text);
        };
        if (delta.object.get("tool_calls")) |tools| {
            if (tools != .array) return error.InvalidResponse;
            for (tools.array.items) |tool| {
                const index_value = try wire.field(tool, "index");
                if (index_value != .integer or index_value.integer < 0 or index_value.integer >= max_tool_calls) return error.InvalidResponse;
                const index: usize = @intCast(index_value.integer);
                while (self.calls.items.len <= index) try self.calls.append(self.alloc, .{});
                const call = &self.calls.items[index];
                if (tool.object.get("id")) |value| try identity(self.alloc, &call.id, try wire.text(value));
                if (tool.object.get("function")) |function| {
                    if (function != .object) return error.InvalidResponse;
                    if (function.object.get("name")) |value| try identity(self.alloc, &call.name, try wire.text(value));
                    if (function.object.get("arguments")) |value| try append_bounded(self.alloc, &call.arguments, try wire.text(value));
                }
            }
        }
    }

    /// Splits preserve UTF-8 boundaries and respect the host's per-delta handoff cap.
    fn emit_text(self: *Context, kind: []const u8, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            var end = @min(offset + max_delta_bytes, text.len);
            while (end < text.len and text[end] & utf8_tag_mask == utf8_continuation_tag) end -= 1;
            try self.output.send(.{ .jsonrpc = wire.jsonrpc, .method = event_method, .params = .{
                .request_id = self.id,
                .handle = self.handle,
                .type = kind,
                .delta = text[offset..end],
            } });
            offset = end;
        }
    }

    /// Opaque replay retains even empty reasoning; tool execution still belongs exclusively to fx.
    pub fn reply(self: *Context) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        var calls: std.json.Array = .init(alloc);
        for (self.calls.items) |call| {
            if (call.id.len == 0 or call.name.len == 0) return error.InvalidResponse;
            var arguments = try std.json.parseFromSlice(Value, alloc, call.arguments.items, .{});
            defer arguments.deinit();
            if (arguments.value != .object) return error.InvalidResponse;
            var value = wire.object();
            try wire.put(alloc, &value, "id", wire.string(call.id));
            try wire.put(alloc, &value, "name", wire.string(call.name));
            try wire.put(alloc, &value, "arguments_json", wire.string(call.arguments.items));
            try calls.append(value);
            try self.output.send(.{ .jsonrpc = wire.jsonrpc, .method = event_method, .params = .{
                .request_id = self.id,
                .handle = self.handle,
                .type = "tool_started",
                .id = call.id,
                .name = call.name,
            } });
            try self.output.send(.{ .jsonrpc = wire.jsonrpc, .method = event_method, .params = .{
                .request_id = self.id,
                .handle = self.handle,
                .type = "tool_input_delta",
                .id = call.id,
                .delta = call.arguments.items,
            } });
        }
        var state = wire.object();
        try wire.put(alloc, &state, "reasoning_content", wire.string(self.reasoning.items));
        var states: std.json.Array = .init(alloc);
        try states.append(state);
        const replay = if (self.reasoning_seen) try std.json.Stringify.valueAlloc(alloc, Value{ .array = states }, .{}) else null;
        try self.output.reply(self.id, .{ .content = if (self.content.items.len > 0) self.content.items else null, .tool_calls = Value{ .array = calls }, .provider_state_json = replay, .finish_reason = self.finish, .usage = .{ .input_tokens = self.input_tokens, .output_tokens = self.output_tokens } });
    }
};

/// Repeated identity fields must agree; fragment indexes cannot repurpose existing calls.
fn identity(alloc: Allocator, owned: *[]const u8, value: []const u8) !void {
    if (value.len == 0 or value.len > max_identity_bytes) return error.InvalidResponse;
    for (value) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.InvalidResponse;
    if (owned.len == 0) owned.* = try alloc.dupe(u8, value) else if (!std.mem.eql(u8, owned.*, value)) return error.InvalidResponse;
}
fn append_bounded(alloc: Allocator, buffer: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_text_bytes - buffer.items.len) return error.ResponseTooLarge;
    try buffer.appendSlice(alloc, text);
}
fn token_count(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}
