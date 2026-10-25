//! The harness wire format: JSON lines over one Unix socket connection per
//! request. The client sends one request line; the host answers with zero or
//! more event lines and then exactly one final line. A one-way op, such as
//! `process`, gets no answer.
//!
//!   request  {"v":1,"token":"<64 hex>","id":7,"op":"tool","args":{...}}
//!   event    {"id":7,"event":"stdout","data":"..."}
//!   final    {"id":7,"ok":true,"value":<json>}
//!            {"id":7,"ok":false,"error":{"kind":"refused","message":"...","output":"..."}}
const std = @import("std");
const lease_mod = @import("lease.zig");
const Allocator = std.mem.Allocator;

pub const version: u32 = 1;
/// Longest request line, which bounds kernel code and tool arguments.
pub const max_request_bytes: usize = 4 << 20;

pub const ErrorKind = enum {
    /// The token names no live command of this node.
    unauthorized,
    bad_request,
    unknown_op,
    /// The host cannot serve this here, such as a completion with no turn.
    unavailable,
    /// The node may not do it.
    refused,
    permission_denied,
    tool_failed,
    kernel_failed,
    cancelled,
    /// Too many requests are in flight for this node.
    busy,
    internal,
};

pub const Envelope = struct {
    v: u32,
    token: []const u8,
    id: i64 = 0,
    op: []const u8,
    args: std.json.Value = .null,
};

pub const Failure = struct {
    kind: ErrorKind,
    message: []const u8,
    /// Text the failed action produced, such as a tool's output.
    output: ?[]const u8 = null,
};

pub const Reply = union(enum) {
    /// One serialized JSON value.
    value: []const u8,
    failure: Failure,
    /// A one-way op: nothing is written.
    none,
};

/// Writes lines to one connection. Event writes may come from another
/// thread, such as a kernel's output reader, so every line takes the lock.
pub const Sink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, line: []const u8) void,
};

/// One request being served: what an op handler sees.
pub const Call = struct {
    arena: Allocator,
    lease: *lease_mod.Lease,
    id: i64,
    sink: Sink,

    /// Streams a text event to the client. Failures only drop the event.
    pub fn event(self: *const Call, name: []const u8, data: []const u8) void {
        var line: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer line.deinit();
        std.json.Stringify.value(.{ .id = self.id, .event = name, .data = data }, .{}, &line.writer) catch return;
        line.writer.writeByte('\n') catch return;
        self.sink.write_fn(self.sink.context, line.written());
    }

    /// Serializes `value` as the request's result.
    pub fn ok(self: *const Call, value: anytype) !Reply {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        try std.json.Stringify.value(value, .{}, &out.writer);
        return .{ .value = out.written() };
    }

    pub fn fail(self: *const Call, kind: ErrorKind, comptime fmt: []const u8, args: anytype) !Reply {
        return .{ .failure = .{ .kind = kind, .message = try self.arena.print(fmt, args) } };
    }
};

/// The final line for `reply`, newline included.
pub fn finalLine(alloc: Allocator, id: i64, reply: Reply) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    switch (reply) {
        .none => return out.toOwnedSlice(),
        .value => |value| try w.print("{{\"id\":{d},\"ok\":true,\"value\":{s}}}\n", .{ id, value }),
        .failure => |failure| {
            try std.json.Stringify.value(.{
                .id = id,
                .ok = false,
                .@"error" = .{ .kind = @tagName(failure.kind), .message = failure.message, .output = failure.output },
            }, .{ .emit_null_optional_fields = false }, w);
            try w.writeByte('\n');
        },
    }
    return out.toOwnedSlice();
}

/// Parses one request line. The arena owns everything it returns.
pub fn parseEnvelope(arena: Allocator, line: []const u8) !Envelope {
    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, line, .{ .ignore_unknown_fields = false });
    if (envelope.v != version) return error.UnsupportedVersion;
    return envelope;
}

/// Typed arguments for an op; unknown fields are refused so a client
/// cannot smuggle a node or session id the host would ignore.
pub fn parseArgs(comptime Args: type, arena: Allocator, value: std.json.Value) !Args {
    if (Args == void) return {};
    const source: std.json.Value = if (value == .null) .{ .object = .empty } else value;
    return std.json.parseFromValueLeaky(Args, arena, source, .{ .ignore_unknown_fields = false });
}

test "the final line carries a value or a typed error" {
    const alloc = std.testing.allocator;
    const good = try finalLine(alloc, 3, .{ .value = "{\"a\":1}" });
    defer alloc.free(good);
    try std.testing.expectEqualStrings("{\"id\":3,\"ok\":true,\"value\":{\"a\":1}}\n", good);
    const bad = try finalLine(alloc, 4, .{ .failure = .{ .kind = .refused, .message = "no \"x\"" } });
    defer alloc.free(bad);
    try std.testing.expectEqualStrings("{\"id\":4,\"ok\":false,\"error\":{\"kind\":\"refused\",\"message\":\"no \\\"x\\\"\"}}\n", bad);
    const none = try finalLine(alloc, 5, .none);
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "requests must name the protocol version and carry no unknown fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const envelope = try parseEnvelope(arena, "{\"v\":1,\"token\":\"t\",\"id\":2,\"op\":\"tool\",\"args\":{\"name\":\"read_file\"}}");
    try std.testing.expectEqualStrings("tool", envelope.op);
    try std.testing.expectError(error.UnsupportedVersion, parseEnvelope(arena, "{\"v\":2,\"token\":\"t\",\"op\":\"tool\"}"));
    try std.testing.expectError(error.UnknownField, parseEnvelope(arena, "{\"v\":1,\"token\":\"t\",\"op\":\"tool\",\"node\":\"other\"}"));
    const Args = struct { name: []const u8 };
    try std.testing.expectEqualStrings("read_file", (try parseArgs(Args, arena, envelope.args)).name);
    const smuggled = try parseEnvelope(arena, "{\"v\":1,\"token\":\"t\",\"op\":\"tool\",\"args\":{\"name\":\"x\",\"node\":\"other\"}}");
    try std.testing.expectError(error.UnknownField, parseArgs(Args, arena, smuggled.args));
}
