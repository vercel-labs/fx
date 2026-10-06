//! Bounded stdio and opaque failures prevent transport details from exposing credentials.
const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const version = 1;
pub const jsonrpc = "2.0";
pub const max_frame_bytes = 8 * 1024 * 1024;
const output_buffer_bytes = 8192;
const failure_code = -32000;
const failure_message = "Provider request failed";

/// Reader storage is copied before another line can replace it; caller owns the result.
pub fn read_line(alloc: Allocator, reader: *std.Io.Reader) !?[]u8 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);
    while (true) {
        const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const bytes = reader.buffered();
                if (bytes.len == 0 or bytes.len > max_frame_bytes - pending.items.len) return error.FrameTooLarge;
                try pending.appendSlice(alloc, bytes);
                reader.tossBuffered();
                continue;
            },
            else => return err,
        } orelse {
            if (pending.items.len == 0) return null;
            return error.IncompleteFrame;
        };
        if (fragment.len > max_frame_bytes - pending.items.len) return error.FrameTooLarge;
        try pending.appendSlice(alloc, fragment);
        return try pending.toOwnedSlice(alloc);
    }
}

/// One output lock prevents worker events from interleaving with cancellation replies.
pub const Output = struct {
    alloc: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn send(self: *Output, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
        defer self.alloc.free(bytes);
        if (bytes.len > max_frame_bytes) return error.FrameTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var buffer: [output_buffer_bytes]u8 = undefined;
        var out = std.Io.File.stdout().writer(self.io, &buffer);
        try out.interface.writeAll(bytes);
        try out.interface.writeByte('\n');
        try out.interface.flush();
    }

    /// Opaque failure text never incorporates provider bodies, header values, or API keys.
    pub fn failure(self: *Output, id: u64) !void {
        try self.send(.{ .jsonrpc = jsonrpc, .id = id, .@"error" = .{ .code = failure_code, .message = failure_message } });
    }

    pub fn reply(self: *Output, id: u64, result: anytype) !void {
        try self.send(.{ .jsonrpc = jsonrpc, .id = id, .result = result });
    }
};

/// Object access rejects a malformed envelope rather than inferring defaults across methods.
pub fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidRequest;
    return value.object.get(name) orelse error.InvalidRequest;
}
pub fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidRequest;
    return value.string;
}
pub fn string(value: []const u8) Value {
    return .{ .string = value };
}
pub fn object() Value {
    return .{ .object = .empty };
}
pub fn put(alloc: Allocator, value: *Value, name: []const u8, item: Value) !void {
    try value.object.put(alloc, name, item);
}
