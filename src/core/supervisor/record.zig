//! What the supervisor saves and lists about one session.
const std = @import("std");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

const max_heartbeat_prompt_bytes = 64 * 1024;
const max_heartbeat_interval_ms: u64 = 365 * 24 * 60 * 60 * 1000;

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

    /// The listed summary of session `id`, with `pending` requests waiting.
    /// Everything borrows `arena`.
    pub fn summary(record: *const Record, arena: Allocator, id: []const u8, cwd: []const u8, pending: usize) !protocol.SessionSummary {
        var heartbeat_copy = record.heartbeat;
        heartbeat_copy.prompt = try arena.dupe(u8, record.heartbeat.prompt);
        return .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, record.name),
            .cwd = try arena.dupe(u8, cwd),
            .model = try arena.dupe(u8, record.model),
            .mode = if (record.mode.len > 0) try arena.dupe(u8, record.mode) else "auto",
            .status = record.status(pending),
            .heartbeat = heartbeat_copy,
            .error_message = if (record.failure) |failure| try arena.dupe(u8, failure) else null,
            .updated_at_ms = record.updated_at_ms,
        };
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

    /// Whether a viewer would see the same session in both records.
    pub fn sameView(self: *const Record, other: *const Record) bool {
        const eql = std.mem.eql;
        const same_failure = if (self.failure) |failure| other.failure != null and eql(u8, failure, other.failure.?) else other.failure == null;
        const a = self.heartbeat;
        const b = other.heartbeat;
        return same_failure and eql(u8, self.name, other.name) and eql(u8, self.model, other.model) and
            eql(u8, self.mode, other.mode) and self.stopped == other.stopped and self.live == other.live and
            self.saved == other.saved and self.running == other.running and self.updated_at_ms == other.updated_at_ms and
            eql(u8, a.prompt, b.prompt) and a.interval_ms == b.interval_ms and a.next_run_ms == b.next_run_ms and
            a.paused == b.paused and a.run_count == b.run_count;
    }

    /// A restart reopens this session: it has a conversation, or a stop or
    /// failure the user should see.
    pub fn reopens(self: *const Record) bool {
        return (self.live and self.saved) or self.stopped or self.failure != null;
    }

    /// Applies a heartbeat change other than `status` at time `now`. On
    /// failure the record is unchanged.
    pub fn applyHeartbeat(self: *Record, alloc: Allocator, request: protocol.HeartbeatRequest, now: i64) !void {
        switch (request.action) {
            .status => {},
            .set => {
                const interval = request.interval_ms orelse return error.IntervalRequired;
                if (interval < 1000 or interval > max_heartbeat_interval_ms) return error.InvalidInterval;
                const text = request.prompt orelse return error.PromptRequired;
                if (text.len == 0 or text.len > max_heartbeat_prompt_bytes) return error.InvalidPrompt;
                self.setHeartbeat(alloc, .{
                    .prompt = try alloc.dupe(u8, text),
                    .interval_ms = interval,
                    .next_run_ms = now + @as(i64, @intCast(interval)),
                    .paused = false,
                });
            },
            .pause => self.heartbeat.paused = true,
            .@"resume" => {
                if (self.heartbeat.interval_ms == 0) return error.HeartbeatNotConfigured;
                self.heartbeat.paused = false;
                self.heartbeat.next_run_ms = now + @as(i64, @intCast(self.heartbeat.interval_ms));
            },
            .clear => self.setHeartbeat(alloc, .{}),
        }
    }

    /// The heartbeat fires on schedule while the host is open.
    pub fn heartbeatArmed(self: *const Record) bool {
        return !self.stopped and !self.heartbeat.paused and self.heartbeat.interval_ms > 0;
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
    try std.testing.expect(record.sameView(&copy));
    try copy.setName(alloc, "second");
    try std.testing.expect(!record.sameView(&copy));
    try std.testing.expectEqualStrings("first", record.name);
    try std.testing.expectEqualStrings("check", copy.heartbeat.prompt);
    try std.testing.expect(copy.heartbeat.prompt.ptr != record.heartbeat.prompt.ptr);
    try std.testing.expect(copy.heartbeatArmed());
    copy.heartbeat.paused = true;
    try std.testing.expect(!copy.heartbeatArmed());
    copy.heartbeat.paused = false;
    copy.stopped = true;
    try std.testing.expect(!copy.heartbeatArmed());
}

test "heartbeat changes validate before they touch the record" {
    const alloc = std.testing.allocator;
    var record = try Record.init(alloc, "session");
    defer record.deinit(alloc);
    try std.testing.expectError(error.HeartbeatNotConfigured, record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .@"resume" }, 0));
    try std.testing.expectError(error.InvalidInterval, record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .set, .interval_ms = 10, .prompt = "check" }, 0));
    try std.testing.expect(!record.heartbeatArmed());
    try record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .set, .interval_ms = 5000, .prompt = "check" }, 100);
    try std.testing.expect(record.heartbeatArmed());
    try std.testing.expectEqual(@as(i64, 5100), record.heartbeat.next_run_ms);
    try record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .pause }, 200);
    try std.testing.expect(!record.heartbeatArmed());
    try record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .@"resume" }, 300);
    try std.testing.expectEqual(@as(i64, 5300), record.heartbeat.next_run_ms);
    try record.applyHeartbeat(alloc, .{ .session_id = "s", .action = .clear }, 400);
    try std.testing.expect(!record.heartbeatArmed() and record.heartbeat.prompt.len == 0);
}
