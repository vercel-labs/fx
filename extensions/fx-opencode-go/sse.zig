//! Chat completion evidence stays codec-owned while shared results enforce native bounds.
const std = @import("std");
const wire = @import("wire.zig");
const stream_result = @import("stream_result.zig");
const sse_events = @import("sse_events.zig");
const Allocator = wire.Allocator;
const Value = wire.Value;
const done_marker = "[DONE]";
const finish_stop = "stop";
const finish_tools = "tool_calls";
const finish_length = "length";
const finish_filter = "content_filter";

/// Chat owns its terminal marker and legacy replay shape independently of other APIs.
pub const Context = struct {
    alloc: Allocator,
    result: *stream_result.Context,

    /// Only recognized finish evidence followed by DONE can authorize a successful native reply.
    pub fn consume(self: *Context, reader: *std.Io.Reader) !void {
        var events = sse_events.Reader.init(self.alloc, reader, self.result.cancel);
        defer events.deinit();
        var done = false;
        while (try events.next()) |data| {
            defer self.alloc.free(data);
            if (std.mem.eql(u8, data, done_marker)) {
                done = true;
                break;
            }
            try self.chunk(data);
        }
        if (!done or self.result.finish == null) return error.IncompleteResponse;
        // Native tool authority requires both a tool finish and accumulated call evidence.
        if (std.mem.eql(u8, self.result.finish.?, finish_tools) != (self.result.calls.items.len > 0)) return error.InvalidResponse;
        // Existing saved sessions depend on the untagged, single-element Chat reasoning envelope.
        if (self.result.reasoning_seen) {
            const replay = try std.json.Stringify.valueAlloc(self.alloc, .{.{ .reasoning_content = self.result.reasoning.items }}, .{});
            defer self.alloc.free(replay);
            try self.result.set_replay(replay);
        }
    }

    /// Provider errors remain opaque instead of becoming assistant text or retryable completions.
    fn chunk(self: *Context, bytes: []const u8) !void {
        var parsed = try std.json.parseFromSlice(Value, self.alloc, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object or root.object.contains("error")) return error.ProviderFailed;
        if (root.object.get("usage")) |usage| if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |value| self.result.input_tokens = try token_count(value);
            if (usage.object.get("completion_tokens")) |value| self.result.output_tokens = try token_count(value);
        };
        const choices = root.object.get("choices") orelse return error.InvalidResponse;
        if (choices != .array or choices.array.items.len > 1) return error.InvalidResponse;
        if (choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return error.InvalidResponse;
        var finish: ?[]const u8 = null;
        if (choice.object.get("finish_reason")) |value| if (value != .null) {
            const reason = try wire.text(value);
            inline for (.{ finish_stop, finish_tools, finish_length, finish_filter }) |known| {
                if (std.mem.eql(u8, reason, known)) finish = known;
            }
            if (finish == null) return error.InvalidResponse;
            if (self.result.finish) |previous| if (!std.mem.eql(u8, previous, finish.?)) return error.InvalidResponse;
        };
        const delta = try wire.field(choice, "delta");
        if (delta != .object) return error.InvalidResponse;
        if (delta.object.get("content")) |value| if (value != .null) {
            if (self.result.finish != null) return error.InvalidResponse;
            const text = try wire.text(value);
            try self.result.append_content(text);
        };
        if (delta.object.get("reasoning_content")) |value| if (value != .null) {
            if (self.result.finish != null) return error.InvalidResponse;
            const text = try wire.text(value);
            try self.result.append_reasoning(text);
        };
        if (delta.object.get("tool_calls")) |tools| {
            if (tools != .array) return error.InvalidResponse;
            if (self.result.finish != null and tools.array.items.len > 0) return error.InvalidResponse;
            for (tools.array.items) |tool| {
                const index_value = try wire.field(tool, "index");
                if (index_value != .integer or index_value.integer < 0) return error.InvalidResponse;
                const index: usize = @intCast(index_value.integer);
                const id = if (tool.object.get("id")) |value| try wire.text(value) else null;
                const function = tool.object.get("function");
                var name: ?[]const u8 = null;
                var arguments: ?[]const u8 = null;
                if (function) |value| {
                    if (value != .object) return error.InvalidResponse;
                    if (value.object.get("name")) |item| name = try wire.text(item);
                    if (value.object.get("arguments")) |item| arguments = try wire.text(item);
                }
                try self.result.set_call(index, id, name);
                if (arguments) |text| try self.result.append_arguments(index, text);
            }
        }
        // The first terminal chunk may contain its final delta; later chunks cannot revise it.
        if (self.result.finish == null) self.result.finish = finish;
    }
};

/// Negative or noninteger usage cannot become native token accounting.
fn token_count(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}
