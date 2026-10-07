//! Shared bounded results prevent API codecs from bypassing native event and reply limits.
const std = @import("std");
const wire = @import("wire.zig");
const Allocator = wire.Allocator;
const Value = wire.Value;
const event_method = "extension.event";
const content_delta = "content_delta";
const reasoning_delta = "reasoning_delta";
const tool_started = "tool_started";
const tool_input_delta = "tool_input_delta";
const max_replay_bytes = wire.max_frame_bytes;
const max_text_bytes = 1024 * 1024;
const max_delta_bytes = 64 * 1024;
const max_tool_calls = 128;
const max_tool_arguments_bytes = 1024 * 1024;
const max_identity_bytes = 1024;
const terminal_delete_byte = 0x7f;
const utf8_tag_mask = 0xc0;
const utf8_continuation_tag = 0x80;

// Stable copied identities outlive codec JSON while fragments remain private until final validation.
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
    replay: ?[]const u8 = null,
    calls: std.ArrayList(Call) = .empty,
    tool_arguments_bytes: usize = 0,
    finish: ?[]const u8 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,

    /// The worker releases accumulator storage only after serializing the final reply.
    pub fn deinit(self: *Context) void {
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        if (self.replay) |json| self.alloc.free(json);
        for (self.calls.items) |*call| {
            if (call.id.len > 0) self.alloc.free(call.id);
            if (call.name.len > 0) self.alloc.free(call.name);
            call.arguments.deinit(self.alloc);
        }
        self.calls.deinit(self.alloc);
    }

    /// Codec buffers can be reused immediately after bounded native publication.
    pub fn append_content(self: *Context, text: []const u8) !void {
        try append_bounded(self.alloc, &self.content, text);
        try self.emit_text(content_delta, text);
    }

    /// Empty reasoning still matters to provider replay across tool continuations.
    pub fn append_reasoning(self: *Context, text: []const u8) !void {
        self.reasoning_seen = true;
        try append_bounded(self.alloc, &self.reasoning, text);
        try self.emit_text(reasoning_delta, text);
    }

    /// Partial identities may arrive separately, but an index cannot change an established call.
    pub fn set_call(self: *Context, index: usize, id: ?[]const u8, name: ?[]const u8) !void {
        if (index >= max_tool_calls) return error.InvalidResponse;
        while (self.calls.items.len <= index) try self.calls.append(self.alloc, .{});
        const call = &self.calls.items[index];
        if (id) |value| try identity(self.alloc, &call.id, value);
        if (name) |value| try identity(self.alloc, &call.name, value);
    }

    /// Aggregate bounds protect the host even when a provider spreads arguments over many calls.
    pub fn append_arguments(self: *Context, index: usize, text: []const u8) !void {
        try self.set_call(index, null, null);
        if (text.len > max_tool_arguments_bytes - self.tool_arguments_bytes) return error.ResponseTooLarge;
        try append_bounded(self.alloc, &self.calls.items[index].arguments, text);
        self.tool_arguments_bytes += text.len;
    }

    /// Context owns the bounded opaque envelope so temporary codec JSON cannot escape its lifetime.
    pub fn set_replay(self: *Context, json: []const u8) !void {
        if (json.len > max_replay_bytes) return error.ResponseTooLarge;
        const owned = try self.alloc.dupe(u8, json);
        if (self.replay) |previous| self.alloc.free(previous);
        self.replay = owned;
    }

    /// Splits preserve UTF-8 boundaries and respect the host's per-delta handoff cap.
    fn emit_text(self: *Context, kind: []const u8, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            if (self.cancel.load(.seq_cst)) return error.Cancelled;
            const end = delta_end(text, offset);
            try self.output.send(.{ .jsonrpc = wire.jsonrpc, .method = event_method, .params = .{
                .request_id = self.id,
                .handle = self.handle,
                .type = kind,
                .delta = text[offset..end],
            } });
            offset = end;
        }
    }

    /// Codec-owned replay passes through unchanged; tool execution still belongs exclusively to fx.
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
                .type = tool_started,
                .id = call.id,
                .name = call.name,
            } });
            var offset: usize = 0;
            while (offset < call.arguments.items.len) {
                if (self.cancel.load(.seq_cst)) return error.Cancelled;
                const end = delta_end(call.arguments.items, offset);
                try self.output.send(.{ .jsonrpc = wire.jsonrpc, .method = event_method, .params = .{
                    .request_id = self.id,
                    .handle = self.handle,
                    .type = tool_input_delta,
                    .id = call.id,
                    .delta = call.arguments.items[offset..end],
                } });
                offset = end;
            }
        }
        try self.output.reply(self.id, .{ .content = if (self.content.items.len > 0) self.content.items else null, .tool_calls = Value{ .array = calls }, .provider_state_json = self.replay, .finish_reason = self.finish, .usage = .{ .input_tokens = self.input_tokens, .output_tokens = self.output_tokens } });
    }
};

/// Both text and tool deltas retain complete UTF-8 characters within the host cap.
fn delta_end(text: []const u8, offset: usize) usize {
    var end = @min(offset + max_delta_bytes, text.len);
    while (end < text.len and text[end] & utf8_tag_mask == utf8_continuation_tag) end -= 1;
    return end;
}

/// Repeated identity fields must agree; fragment indexes cannot repurpose existing calls.
fn identity(alloc: Allocator, owned: *[]const u8, value: []const u8) !void {
    if (value.len == 0 or value.len > max_identity_bytes) return error.InvalidResponse;
    for (value) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.InvalidResponse;
    if (owned.len == 0) owned.* = try alloc.dupe(u8, value) else if (!std.mem.eql(u8, owned.*, value)) return error.InvalidResponse;
}

/// Independent text bounds prevent codecs from retaining unbounded transcript or call storage.
fn append_bounded(alloc: Allocator, buffer: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_text_bytes - buffer.items.len) return error.ResponseTooLarge;
    try buffer.appendSlice(alloc, text);
}
