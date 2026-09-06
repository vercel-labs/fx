const std = @import("std");
const types = @import("../../shared/types.zig");
const checkpoint_codec = @import("checkpoint.zig");

const Allocator = std.mem.Allocator;

/// The provider-neutral state for one conversation. Product session metadata,
/// persistence, permissions, credentials, and host effects live outside it.
pub const Agent = struct {
    history: std.ArrayList(types.HistoryTurn) = .empty,
    turn_usage: types.Usage = .{},
    fresh: bool = true,

    pub fn deinit(self: *Agent, alloc: Allocator) void {
        self.clearHistory(alloc);
        self.history.deinit(alloc);
        self.* = undefined;
    }

    pub fn startTurn(self: *Agent) void {
        self.fresh = false;
        self.turn_usage = .{};
    }

    pub fn checkpoint(self: *const Agent, alloc: Allocator) checkpoint_codec.Error![]u8 {
        return checkpoint_codec.encode(alloc, self.history.items, self.turn_usage);
    }

    pub fn restoreCheckpoint(
        self: *Agent,
        alloc: Allocator,
        bytes: []const u8,
    ) (checkpoint_codec.Error || error{AgentNotFresh})!void {
        if (!self.fresh or self.history.items.len != 0) {
            return error.AgentNotFresh;
        }
        var decoded = try checkpoint_codec.decode(alloc, bytes);
        defer decoded.deinit(alloc);
        var previous = self.history;
        self.history = .fromOwnedSlice(decoded.history);
        decoded.history = &.{};
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);
        self.turn_usage = decoded.usage;
        self.fresh = false;
    }

    pub fn observeUsage(self: *Agent, usage: types.Usage) void {
        addOptional(&self.turn_usage.input_tokens, usage.input_tokens);
        addOptional(&self.turn_usage.output_tokens, usage.output_tokens);
        addOptional(&self.turn_usage.cache_read_tokens, usage.cache_read_tokens);
        addOptional(&self.turn_usage.cache_write_tokens, usage.cache_write_tokens);
        addOptional(&self.turn_usage.reasoning_tokens, usage.reasoning_tokens);
    }

    pub fn appendHistoryEntry(
        self: *Agent,
        alloc: Allocator,
        turn: types.HistoryTurn,
    ) Allocator.Error!void {
        const copy = try types.dupeHistoryTurn(alloc, turn);
        errdefer types.freeHistoryTurn(alloc, copy);
        try self.history.append(alloc, copy);
        self.fresh = false;
    }

    pub fn clearHistory(self: *Agent, alloc: Allocator) void {
        for (self.history.items) |turn| types.freeHistoryTurn(alloc, turn);
        self.history.clearRetainingCapacity();
    }

    pub fn snapshotHistory(
        self: *const Agent,
        alloc: Allocator,
    ) Allocator.Error![]types.HistoryTurn {
        const copy = try alloc.alloc(types.HistoryTurn, self.history.items.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |turn| types.freeHistoryTurn(alloc, turn);
            alloc.free(copy);
        }
        for (self.history.items, 0..) |turn, index| {
            copy[index] = try types.dupeHistoryTurn(alloc, turn);
            copied += 1;
        }
        return copy;
    }

    pub fn restoreHistory(
        self: *Agent,
        alloc: Allocator,
        history: []const types.HistoryTurn,
    ) Allocator.Error!void {
        var replacement: std.ArrayList(types.HistoryTurn) = .empty;
        errdefer {
            for (replacement.items) |turn| types.freeHistoryTurn(alloc, turn);
            replacement.deinit(alloc);
        }
        try replacement.ensureTotalCapacity(alloc, history.len);
        for (history) |turn| {
            replacement.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
        }

        var previous = self.history;
        self.history = replacement;
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);
        self.fresh = false;
    }
};

fn addOptional(total: *?u64, value: ?u64) void {
    const amount = value orelse return;
    total.* = std.math.add(u64, total.* orelse 0, amount) catch std.math.maxInt(u64);
}

test "Agent startTurn consumes freshness and resets usage" {
    var agent: Agent = .{};
    agent.turn_usage = .{ .input_tokens = 4 };
    agent.startTurn();
    try std.testing.expect(!agent.fresh);
    try std.testing.expectEqual(@as(?u64, null), agent.turn_usage.input_tokens);
}

test "Agent accumulates per-turn usage with saturation" {
    var agent: Agent = .{};
    agent.startTurn();
    agent.observeUsage(.{ .input_tokens = 4, .output_tokens = 2 });
    agent.observeUsage(.{ .input_tokens = 3, .reasoning_tokens = 1 });
    try std.testing.expectEqual(@as(?u64, 7), agent.turn_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), agent.turn_usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), agent.turn_usage.reasoning_tokens);

    agent.observeUsage(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        agent.turn_usage.input_tokens,
    );
}

test "Agent history restore is transactional" {
    const alloc = std.testing.allocator;
    var agent: Agent = .{};
    defer agent.deinit(alloc);

    try agent.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("old") },
        .assistant = @constCast("answer"),
    } });
    const replacement = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("new") },
        .assistant = @constCast("response"),
    } }};
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        agent.restoreHistory(failing.allocator(), &replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), agent.history.items.len);
    try std.testing.expectEqualStrings("old", agent.history.items[0].assistant.user.text);

    try agent.restoreHistory(alloc, &replacement);
    try std.testing.expectEqualStrings("new", agent.history.items[0].assistant.user.text);
}

test "Agent checkpoint restores only into a fresh owner" {
    const alloc = std.testing.allocator;
    var source: Agent = .{};
    defer source.deinit(alloc);
    try source.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("before") },
        .assistant = @constCast("after"),
    } });
    const bytes = try source.checkpoint(alloc);
    defer alloc.free(bytes);

    var restored: Agent = .{};
    defer restored.deinit(alloc);
    try restored.restoreCheckpoint(alloc, bytes);
    try std.testing.expectEqualStrings("before", restored.history.items[0].assistant.user.text);
    try std.testing.expectError(error.AgentNotFresh, restored.restoreCheckpoint(alloc, bytes));
}

test "Agent checkpoint restore consumes freshness for empty history" {
    const alloc = std.testing.allocator;
    var source: Agent = .{};
    defer source.deinit(alloc);
    const bytes = try source.checkpoint(alloc);
    defer alloc.free(bytes);

    var restored: Agent = .{};
    defer restored.deinit(alloc);
    try restored.restoreCheckpoint(alloc, bytes);
    try std.testing.expectError(error.AgentNotFresh, restored.restoreCheckpoint(alloc, bytes));
}
