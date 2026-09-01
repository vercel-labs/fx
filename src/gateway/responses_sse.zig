const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const responses_protocol = @import("responses_protocol.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    line_bytes: usize,
    aggregate_bytes: usize,
    events: usize,
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    provider_state_bytes: usize,
};

const Reader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *Reader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *Reader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *Reader, alloc: Allocator, reader: anytype, max_line_bytes: usize) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader, max_line_bytes) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *Reader, alloc: Allocator, reader: anytype, max_line_bytes: usize) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.ResponsesSseReadStalled;
                    if (buffered.len > max_line_bytes -| self.pending_line.items.len) {
                        return error.ResponsesSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_line_bytes -| self.pending_line.items.len) {
                return error.ResponsesSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
        }
    }
};

pub fn consume(
    alloc: Allocator,
    reader: anytype,
    callbacks: responses_protocol.StreamCallbacks,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
    limits: Limits,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: Reader = .{};
    defer sse.deinit(alloc);
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = limits.aggregate_bytes,
        .events = limits.events,
        .tool_calls = limits.tool_calls,
        .tool_identity_bytes = limits.tool_identity_bytes,
        .tool_arguments_bytes = limits.tool_arguments_bytes,
        .provider_state_bytes = limits.provider_state_bytes,
    };
    while (try sse.next(alloc, reader, limits.line_bytes)) |json_text| {
        defer sse.release();
        if (try reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            stream_limits,
        )) break;
    }
    return reducer.finish(alloc, cancel_flag, stream_limits);
}
