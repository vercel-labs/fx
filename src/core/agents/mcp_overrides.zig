const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const max_entries = 256;

pub const Entry = struct {
    name: []const u8,
    enabled: bool,
};

/// Temporary MCP choices for one root session. Names are owned by the state;
/// readers copy values while the mutex is held and retain no borrowed storage.
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    pub fn get(self: *State, name: []const u8) ?bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.enabled;
        return null;
    }

    /// Null restores the configured default. Failure leaves the choices intact.
    pub fn set(self: *State, alloc: Allocator, name: []const u8, enabled: ?bool) error{ OutOfMemory, McpOverrideLimitReached }!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items, 0..) |*entry, i| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (enabled) |value| {
                entry.enabled = value;
            } else {
                alloc.free(entry.name);
                _ = self.entries.orderedRemove(i);
            }
            return;
        }
        const value = enabled orelse return;
        if (self.entries.items.len >= max_entries) return error.McpOverrideLimitReached;
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.entries.append(alloc, .{ .name = owned, .enabled = value });
    }

    /// Caller owns the slice and each entry's name; release with freeSnapshot.
    pub fn snapshot(self: *State, alloc: Allocator) Allocator.Error![]Entry {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const out = try alloc.alloc(Entry, self.entries.items.len);
        var copied: usize = 0;
        errdefer {
            for (out[0..copied]) |entry| alloc.free(entry.name);
            alloc.free(out);
        }
        for (self.entries.items, out) |entry, *dest| {
            dest.* = .{ .name = try alloc.dupe(u8, entry.name), .enabled = entry.enabled };
            copied += 1;
        }
        return out;
    }

    pub fn freeSnapshot(alloc: Allocator, entries: []Entry) void {
        for (entries) |entry| alloc.free(entry.name);
        alloc.free(entries);
    }

    pub fn clear(self: *State, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.entries.items) |entry| alloc.free(entry.name);
        self.entries.clearRetainingCapacity();
    }

    /// The owning session has stopped every worker before freeing its state.
    pub fn deinit(self: *State, alloc: Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
        self.* = .{};
    }
};

test "temporary MCP choices replace, reset, snapshot, and remain session-local" {
    const alloc = std.testing.allocator;
    var first: State = .{};
    defer first.deinit(alloc);
    var second: State = .{};
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, null), first.get("server"));
    try first.set(alloc, "server", true);
    try std.testing.expectEqual(@as(?bool, true), first.get("server"));
    try std.testing.expectEqual(@as(?bool, null), second.get("server"));
    const copied = try first.snapshot(alloc);
    defer State.freeSnapshot(alloc, copied);
    try first.set(alloc, "server", false);
    try std.testing.expect(copied[0].enabled);
    try std.testing.expectEqual(@as(?bool, false), first.get("server"));
    try first.set(alloc, "server", null);
    try std.testing.expectEqual(@as(?bool, null), first.get("server"));
    try first.set(alloc, "missing", null);
    try first.set(alloc, "server", true);
    first.clear(alloc);
    try std.testing.expectEqual(@as(?bool, null), first.get("server"));
}

test "temporary MCP choices clean up partial allocations" {
    const testing_allocator = @import("../shared/testing_allocator.zig");
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkAllocations, .{});
}

fn checkAllocations(alloc: Allocator) !void {
    var state: State = .{};
    defer state.deinit(alloc);
    try state.set(alloc, "first", true);
    try state.set(alloc, "second", false);
    const values = try state.snapshot(alloc);
    defer State.freeSnapshot(alloc, values);
}

test "temporary MCP choices have a fixed entry bound" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    for (0..max_entries) |i| {
        const name = try alloc.print("server-{d}", .{i});
        defer alloc.free(name);
        try state.set(alloc, name, true);
    }
    try std.testing.expectError(error.McpOverrideLimitReached, state.set(alloc, "overflow", true));
    try state.set(alloc, "server-0", false);
    try state.set(alloc, "server-1", null);
    try state.set(alloc, "overflow", true);
}
