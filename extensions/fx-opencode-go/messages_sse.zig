//! Complete Messages lifecycle evidence protects native tools and reasoning replay from partial streams.
const std = @import("std");
const wire = @import("wire.zig");
const events = @import("sse_events.zig");
const stream_result = @import("stream_result.zig");
const messages_request = @import("messages_request.zig");
const replay = @import("replay.zig");
const max_blocks = 1024;
const max_replay_blocks = 128;
const max_block_bytes = 1024 * 1024;
const max_replay_bytes = wire.max_frame_bytes;
const message_type = "message";
const assistant_role = "assistant";
const event_start = "message_start";
const event_block_start = "content_block_start";
const event_block_delta = "content_block_delta";
const event_block_stop = "content_block_stop";
const event_delta = "message_delta";
const event_stop = "message_stop";
const event_error = "error";
const text_type = "text";
const thinking_type = "thinking";
const redacted_type = "redacted_thinking";
const tool_type = "tool_use";
const text_delta_type = "text_delta";
const thinking_delta_type = "thinking_delta";
const signature_delta_type = "signature_delta";
const input_delta_type = "input_json_delta";
const end_turn_reason = "end_turn";
const stop_sequence_reason = "stop_sequence";
const max_tokens_reason = "max_tokens";
const tool_reason = "tool_use";
const finish_stop = "stop";
const finish_length = "length";
const finish_tools = "tool_calls";
const usage_cache_fields = [_][]const u8{ "cache_creation_input_tokens", "cache_read_input_tokens" };

// One active typed block prevents deltas from crossing tool, text and thinking boundaries.
const Kind = enum { text, thinking, redacted, tool };
const Block = struct {
    kind: Kind,
    call_index: usize = 0,
    initial_input: ?wire.Value = null,
    redacted: ?wire.Value = null,
    thinking: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    signature_seen: bool = false,
    input_started: bool = false,

    /// Local buffers are released at block closure and again safely on any stream failure.
    fn deinit(self: *Block, alloc: wire.Allocator) void {
        self.thinking.deinit(alloc);
        self.signature.deinit(alloc);
    }
};

/// Result owns canonical output; this call owns and bounds all framing and replay construction.
pub fn consume(result: *stream_result.Context, reader: *std.Io.Reader) !void {
    var arena = std.heap.ArenaAllocator.init(result.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    var framing = events.Reader.init(result.alloc, reader, result.cancel);
    defer framing.deinit();
    var started = false;
    var terminal = false;
    var blocks: usize = 0;
    var active: ?Block = null;
    defer if (active) |*block| block.deinit(result.alloc);
    var saved: std.json.Array = .init(alloc);
    var replay_bytes: usize = 0;
    while (try framing.next()) |data| {
        defer result.alloc.free(data);
        var parsed = try std.json.parseFromSlice(wire.Value, result.alloc, data, .{});
        defer parsed.deinit();
        const event = parsed.value;
        const kind = try wire.text(try wire.field(event, "type"));
        if (std.mem.eql(u8, kind, event_error)) return error.ProviderFailed;
        if (std.mem.eql(u8, kind, event_start)) {
            if (started or terminal) return error.InvalidResponse;
            const message = try wire.field(event, "message");
            if (!std.mem.eql(u8, try wire.text(try wire.field(message, "type")), message_type) or
                !std.mem.eql(u8, try wire.text(try wire.field(message, "role")), assistant_role)) return error.InvalidResponse;
            const content = try wire.field(message, "content");
            if (content != .array or content.array.items.len != 0) return error.InvalidResponse;
            // Qwen omits stop_reason at start; a non-null value would claim premature completion.
            if (message.object.get("stop_reason")) |reason| if (reason != .null) return error.InvalidResponse;
            if (message.object.get("usage")) |usage| try apply_usage(result, usage);
            started = true;
        } else if (std.mem.eql(u8, kind, event_block_start)) {
            if (!started or terminal or active != null or blocks >= max_blocks or try block_index(event) != blocks) return error.InvalidResponse;
            const block = try wire.field(event, "content_block");
            const block_type = try wire.text(try wire.field(block, "type"));
            if (std.mem.eql(u8, block_type, text_type)) {
                active = .{ .kind = .text };
                try result.append_content(try wire.text(try wire.field(block, "text")));
            } else if (std.mem.eql(u8, block_type, thinking_type)) {
                if (block != .object or block.object.count() != 3) return error.InvalidResponse;
                active = .{ .kind = .thinking };
                const thinking = try wire.text(try wire.field(block, "thinking"));
                try append_block(result.alloc, &active.?.thinking, thinking);
                try append_block(result.alloc, &active.?.signature, try wire.text(try wire.field(block, "signature")));
                active.?.signature_seen = active.?.signature.items.len > 0;
                try result.append_reasoning(thinking);
            } else if (std.mem.eql(u8, block_type, redacted_type)) {
                try messages_request.validate_replay_block(block);
                active = .{ .kind = .redacted, .redacted = try clone(alloc, block) };
            } else if (std.mem.eql(u8, block_type, tool_type)) {
                const id = try wire.text(try wire.field(block, "id"));
                for (result.calls.items) |call| if (std.mem.eql(u8, call.id, id)) return error.InvalidResponse;
                const dense = result.calls.items.len;
                try result.set_call(dense, id, try wire.text(try wire.field(block, "name")));
                const input = try wire.field(block, "input");
                if (input != .object) return error.InvalidResponse;
                active = .{ .kind = .tool, .call_index = dense, .initial_input = try clone(alloc, input) };
            } else return error.InvalidResponse;
        } else if (std.mem.eql(u8, kind, event_block_delta)) {
            if (!started or terminal or active == null or try block_index(event) != blocks) return error.InvalidResponse;
            const block = &active.?;
            const delta = try wire.field(event, "delta");
            const delta_type = try wire.text(try wire.field(delta, "type"));
            if (block.kind == .text and std.mem.eql(u8, delta_type, text_delta_type)) {
                try result.append_content(try wire.text(try wire.field(delta, "text")));
            } else if (block.kind == .thinking and std.mem.eql(u8, delta_type, thinking_delta_type)) {
                // A signature terminates thinking text; later text would invalidate its meaning.
                if (block.signature_seen) return error.InvalidResponse;
                const thinking = try wire.text(try wire.field(delta, "thinking"));
                try append_block(result.alloc, &block.thinking, thinking);
                try result.append_reasoning(thinking);
            } else if (block.kind == .thinking and std.mem.eql(u8, delta_type, signature_delta_type)) {
                try append_block(result.alloc, &block.signature, try wire.text(try wire.field(delta, "signature")));
                block.signature_seen = true;
            } else if (block.kind == .tool and std.mem.eql(u8, delta_type, input_delta_type)) {
                if (block.initial_input.?.object.count() != 0) return error.InvalidResponse;
                const fragment = try wire.text(try wire.field(delta, "partial_json"));
                try result.append_arguments(block.call_index, fragment);
                if (fragment.len > 0) block.input_started = true;
            } else return error.InvalidResponse;
        } else if (std.mem.eql(u8, kind, event_block_stop)) {
            if (!started or terminal or active == null or try block_index(event) != blocks) return error.InvalidResponse;
            const block = &active.?;
            if (block.kind == .tool) {
                if (!block.input_started) try result.append_arguments(block.call_index, try std.json.Stringify.valueAlloc(alloc, block.initial_input.?, .{}));
                var input = try std.json.parseFromSlice(wire.Value, result.alloc, result.calls.items[block.call_index].arguments.items, .{});
                defer input.deinit();
                if (input.value != .object) return error.InvalidResponse;
            } else if (block.kind == .thinking or block.kind == .redacted) {
                var item = block.redacted orelse wire.object();
                if (block.kind == .thinking) {
                    if (!block.signature_seen) return error.InvalidResponse;
                    try wire.put(alloc, &item, "type", wire.string(thinking_type));
                    try wire.put(alloc, &item, "thinking", wire.string(try alloc.dupe(u8, block.thinking.items)));
                    try wire.put(alloc, &item, "signature", wire.string(try alloc.dupe(u8, block.signature.items)));
                }
                try messages_request.validate_replay_block(item);
                const encoded = try std.json.Stringify.valueAlloc(alloc, item, .{});
                if (saved.items.len >= max_replay_blocks or encoded.len > max_replay_bytes - replay_bytes) return error.ResponseTooLarge;
                replay_bytes += encoded.len;
                try saved.append(item);
            }
            block.deinit(result.alloc);
            active = null;
            blocks += 1;
        } else if (std.mem.eql(u8, kind, event_delta)) {
            if (!started or active != null) return error.InvalidResponse;
            const reason = try wire.field(try wire.field(event, "delta"), "stop_reason");
            if (reason != .null) {
                const finish = try finish_reason(try wire.text(reason));
                if (terminal and !std.mem.eql(u8, result.finish.?, finish)) return error.InvalidResponse;
                result.finish = finish;
                terminal = true;
            }
            if (event.object.get("usage")) |usage| try apply_usage(result, usage);
        } else if (std.mem.eql(u8, kind, event_stop)) {
            if (!started or !terminal or active != null) return error.IncompleteResponse;
            const tools = std.mem.eql(u8, result.finish.?, finish_tools);
            if (tools != (result.calls.items.len > 0)) return error.InvalidResponse;
            if (saved.items.len > 0) try result.set_replay(try replay.envelope(alloc, .messages, .{ .array = saved }));
            return;
        }
    }
    return error.IncompleteResponse;
}

/// Only documented terminal reasons can authorize a canonical native completion.
fn finish_reason(reason: []const u8) ![]const u8 {
    if (std.mem.eql(u8, reason, end_turn_reason) or std.mem.eql(u8, reason, stop_sequence_reason)) return finish_stop;
    if (std.mem.eql(u8, reason, max_tokens_reason)) return finish_length;
    if (std.mem.eql(u8, reason, tool_reason)) return finish_tools;
    return error.InvalidResponse;
}

/// Dense content indexes reject re-opened blocks without allocating hostile sparse storage.
fn block_index(event: wire.Value) !usize {
    const index = try wire.field(event, "index");
    if (index != .integer or index.integer < 0 or index.integer >= max_blocks) return error.InvalidResponse;
    return @intCast(index.integer);
}

/// Small per-block bounds also cover signature fragments that never appear in native text.
fn append_block(alloc: wire.Allocator, buffer: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len > max_block_bytes - buffer.items.len) return error.ResponseTooLarge;
    try buffer.appendSlice(alloc, text);
}

/// JSON copied into the codec arena remains valid after each event parse is released.
fn clone(alloc: wire.Allocator, value: wire.Value) !wire.Value {
    return std.json.parseFromSliceLeaky(wire.Value, alloc, try std.json.Stringify.valueAlloc(alloc, value, .{}), .{ .allocate = .alloc_always });
}

/// Native input totals include cached prompt tokens; Messages output updates are cumulative.
fn apply_usage(result: *stream_result.Context, usage: wire.Value) !void {
    if (usage != .object) return error.InvalidResponse;
    for (usage_cache_fields) |field| if (usage.object.get(field)) |cached| {
        _ = try token_count(cached);
        if (usage.object.get("input_tokens") == null) return error.InvalidResponse;
    };
    if (usage.object.get("input_tokens")) |input| {
        var total = try token_count(input);
        for (usage_cache_fields) |field| if (usage.object.get(field)) |cached| {
            total = std.math.add(u64, total, try token_count(cached)) catch return error.InvalidResponse;
        };
        result.input_tokens = total;
    }
    if (usage.object.get("output_tokens")) |output| result.output_tokens = try token_count(output);
}

/// Invalid numeric usage must not corrupt native persisted session totals.
fn token_count(value: wire.Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}
