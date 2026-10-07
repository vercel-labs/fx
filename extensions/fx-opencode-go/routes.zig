//! Embedded routing binds each admitted wire identity to its credential and codec family.
const std = @import("std");
const configuration = @embedFile("routes.json");
const configuration_buffer_bytes = 32 * 1024;

/// Keeping API families private to the adapter avoids widening the host model protocol.
pub const Api = enum { chat_completions, responses, messages };

// Typed configuration rejects accidental API labels before any provider request can begin.
const Route = struct { wire_id: []const u8, api: Api };

/// A bounded stack allocator keeps route admission independent of credentials and external files.
pub fn resolve(wire_id: []const u8) !Api {
    var buffer: [configuration_buffer_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const parsed = try std.json.parseFromSlice([]const Route, fixed.allocator(), configuration, .{});
    defer parsed.deinit();
    for (parsed.value) |route| {
        if (std.mem.eql(u8, wire_id, route.wire_id)) return route.api;
    }
    return error.UnknownRoute;
}
