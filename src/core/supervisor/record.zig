//! What the supervisor saves and lists about one session.
const std = @import("std");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

/// What the supervisor saves and lists about a session. Only the executor
/// changes it, and only by `commit` for saved fields; readers lock it.
pub const Record = struct {
    name: []u8,
    stopped: bool = false,
    failure: ?[]u8 = null,
    heartbeat: protocol.Heartbeat = .{},
    updated_at_ms: i64 = 0,
    /// The executor holds an open host.
    live: bool = false,
    /// The live host's conversation is on disk.
    saved: bool = false,
    running: bool = false,
    model: []u8 = &.{},
    mode: []u8 = &.{},

    pub fn init(alloc: Allocator, name: []const u8) !Record {
        return .{ .name = try alloc.dupe(u8, name) };
    }

    pub fn clone(self: *const Record, alloc: Allocator) !Record {
        var copy: Record = .{ .name = try alloc.dupe(u8, self.name) };
        errdefer copy.deinit(alloc);
        copy.stopped = self.stopped;
        copy.updated_at_ms = self.updated_at_ms;
        copy.live = self.live;
        copy.saved = self.saved;
        copy.running = self.running;
        if (self.failure) |failure| copy.failure = try alloc.dupe(u8, failure);
        copy.heartbeat = self.heartbeat;
        copy.heartbeat.prompt = "";
        if (self.heartbeat.prompt.len > 0) copy.heartbeat.prompt = try alloc.dupe(u8, self.heartbeat.prompt);
        copy.model = try alloc.dupe(u8, self.model);
        copy.mode = try alloc.dupe(u8, self.mode);
        return copy;
    }

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.failure) |failure| alloc.free(failure);
        if (self.heartbeat.prompt.len > 0) alloc.free(self.heartbeat.prompt);
        alloc.free(self.model);
        alloc.free(self.mode);
        self.* = undefined;
    }

    pub fn setName(self: *Record, alloc: Allocator, name: []const u8) !void {
        const owned = try alloc.dupe(u8, name);
        alloc.free(self.name);
        self.name = owned;
    }

    /// Takes ownership of `prompt`.
    pub fn setHeartbeat(self: *Record, alloc: Allocator, heartbeat: protocol.Heartbeat) void {
        if (self.heartbeat.prompt.len > 0) alloc.free(self.heartbeat.prompt);
        self.heartbeat = heartbeat;
    }

    /// A restart reopens this session: it has a conversation, or a stop or
    /// failure the user should see.
    pub fn reopens(self: *const Record) bool {
        return (self.live and self.saved) or self.stopped or self.failure != null;
    }

    pub fn status(self: *const Record, pending: usize) protocol.Status {
        if (self.failure != null) return .@"error";
        if (self.stopped) return .stopped;
        if (!self.live) return .saved;
        if (pending > 0) return .awaiting_approval;
        return if (self.running) .running else .idle;
    }
};

test "record status follows failure, stop, approval, then activity" {
    var record = try Record.init(std.testing.allocator, "session");
    defer record.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Status.saved, record.status(0));
    record.live = true;
    try std.testing.expectEqual(protocol.Status.idle, record.status(0));
    record.running = true;
    try std.testing.expectEqual(protocol.Status.running, record.status(0));
    try std.testing.expectEqual(protocol.Status.awaiting_approval, record.status(1));
    record.stopped = true;
    try std.testing.expectEqual(protocol.Status.stopped, record.status(1));
    try std.testing.expect(record.reopens());
}

test "record clones own their strings" {
    const alloc = std.testing.allocator;
    var record = try Record.init(alloc, "first");
    defer record.deinit(alloc);
    record.setHeartbeat(alloc, .{ .prompt = try alloc.dupe(u8, "check"), .interval_ms = 1000, .paused = false });
    var copy = try record.clone(alloc);
    defer copy.deinit(alloc);
    try copy.setName(alloc, "second");
    try std.testing.expectEqualStrings("first", record.name);
    try std.testing.expectEqualStrings("check", copy.heartbeat.prompt);
    try std.testing.expect(copy.heartbeat.prompt.ptr != record.heartbeat.prompt.ptr);
}
