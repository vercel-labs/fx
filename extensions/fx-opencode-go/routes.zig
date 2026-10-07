//! Embedded routing binds each admitted wire identity to its credential and codec family.
const std = @import("std");
const configuration = @embedFile("routes.json");
const catalog = @embedFile("models.json");
const configuration_buffer_bytes = 32 * 1024;

/// Keeping API families private to the adapter avoids widening the host model protocol.
pub const Api = enum { chat_completions, responses, messages };

// Typed configuration rejects accidental API labels before any provider request can begin.
const Route = struct { wire_id: []const u8, api: Api };

// Sharing the shipped metadata prevents discovery and wire effort admission from drifting.
const Model = struct { wire_id: []const u8, reasoning_efforts: []const []const u8 };
const Catalog = struct { models: []const Model };

/// A global preference cannot assign unsupported effort semantics to the selected wire identity.
pub fn validate_effort(wire_id: []const u8, effort: std.json.Value) !void {
    if (effort == .null) return;
    if (effort != .string) return error.InvalidReasoningEffort;
    var buffer: [configuration_buffer_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const parsed = try std.json.parseFromSlice(Catalog, fixed.allocator(), catalog, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.models) |model| {
        if (!std.mem.eql(u8, wire_id, model.wire_id)) continue;
        for (model.reasoning_efforts) |allowed| if (std.mem.eql(u8, effort.string, allowed)) return;
        return error.InvalidReasoningEffort;
    }
    return error.UnknownRoute;
}

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
