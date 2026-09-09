const std = @import("std");
const goal_types = @import("goal_types.zig");
const goal_store = @import("goal_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// In-memory accounting state for the active goal's budget consumption. One
/// per session. Tracks the last-accounted token usage baseline and the
/// wall-clock baseline so deltas are computed only once per turn boundary.
pub const AccountingState = struct {
    last_accounted_input: u64 = 0,
    last_accounted_output: u64 = 0,
    last_accounted_at_ms: i64,
    active_goal_id: ?[]const u8 = null,
    /// Owner-allocated id; references borrowed from the goal store.
    goal_id_storage: ?[]u8 = null,
    budget_limit_reported: bool = false,

    pub fn init(now_ms: i64) AccountingState {
        return .{ .last_accounted_at_ms = now_ms };
    }

    pub fn deinit(self: *AccountingState, alloc: Allocator) void {
        if (self.goal_id_storage) |id| alloc.free(id);
        self.* = undefined;
    }

    /// Marks the given goal as active and resets the accounting baseline so
    /// consumption is measured from this point forward.
    pub fn markGoalActive(self: *AccountingState, alloc: Allocator, goal_id: []const u8, now_ms: i64) !void {
        if (self.goal_id_storage) |old| {
            if (std.mem.eql(u8, old, goal_id)) {
                self.last_accounted_at_ms = now_ms;
                self.budget_limit_reported = false;
                return;
            }
            alloc.free(old);
        }
        self.goal_id_storage = try alloc.dupe(u8, goal_id);
        self.active_goal_id = self.goal_id_storage;
        self.last_accounted_input = 0;
        self.last_accounted_output = 0;
        self.last_accounted_at_ms = now_ms;
        self.budget_limit_reported = false;
    }

    pub fn clearActiveGoal(self: *AccountingState, alloc: Allocator) void {
        if (self.goal_id_storage) |old| alloc.free(old);
        self.goal_id_storage = null;
        self.active_goal_id = null;
        self.budget_limit_reported = false;
    }

    pub fn isActiveForGoal(self: *const AccountingState, goal_id: []const u8) bool {
        if (self.active_goal_id) |active| return std.mem.eql(u8, active, goal_id);
        return false;
    }

    /// Computes the token delta since the last accounting checkpoint and
    /// advances the baseline. Returns the delta (0 when the goal is inactive
    /// or no new tokens were consumed).
    pub fn recordUsage(self: *AccountingState, total: types.ToolUsage) i64 {
        const delta_input = total.input_tokens -| self.last_accounted_input;
        const delta_output = total.output_tokens -| self.last_accounted_output;
        self.last_accounted_input = total.input_tokens;
        self.last_accounted_output = total.output_tokens;
        if (self.active_goal_id == null) return 0;
        const delta = @as(i64, @intCast(delta_input)) + @as(i64, @intCast(delta_output));
        return @max(delta, 0);
    }

    /// Computes the elapsed wall-clock seconds since the last accounting
    /// checkpoint and advances the baseline.
    pub fn recordTime(self: *AccountingState, now_ms: i64) i64 {
        const elapsed_ms = now_ms - self.last_accounted_at_ms;
        self.last_accounted_at_ms = now_ms;
        if (self.active_goal_id == null) return 0;
        const seconds = @divFloor(elapsed_ms, std.time.ms_per_s);
        return @max(seconds, 0);
    }

    /// Returns true when reporting budget_limited for the first time on this
    /// goal; false if already reported, so the steering prompt is injected once.
    pub fn markBudgetLimitReportedIfNew(self: *AccountingState) bool {
        if (self.budget_limit_reported) return false;
        self.budget_limit_reported = true;
        return true;
    }
};

/// Updates a goal's cumulative usage by the given deltas and detects whether
/// the budget is now exhausted. Returns the updated goal (caller owns it) and
/// whether the budget limit was newly reached.
pub const AccountingOutcome = struct {
    goal: goal_store.Goal,
    budget_limit_reached: bool,
};

pub fn accountProgress(
    alloc: Allocator,
    goal: goal_store.Goal,
    token_delta: i64,
    time_delta_seconds: i64,
    now_ms: i64,
) !AccountingOutcome {
    var updated = try goal.dupe(alloc);
    updated.tokens_used +|= token_delta;
    updated.time_used_seconds +|= time_delta_seconds;
    updated.updated_at_ms = now_ms;
    const budget_limit_reached = blk: {
        const budget = updated.token_budget orelse break :blk false;
        if (budget <= 0) break :blk false;
        break :blk updated.tokens_used >= budget;
    };
    if (budget_limit_reached) updated.status = .budget_limited;
    return .{ .goal = updated, .budget_limit_reached = budget_limit_reached };
}

test "recordUsage returns delta and advances baseline" {
    const alloc = std.testing.allocator;
    var state = AccountingState.init(0);
    defer state.deinit(alloc);
    try state.markGoalActive(alloc, "g1", 0);
    const delta1 = state.recordUsage(.{ .input_tokens = 100, .output_tokens = 50 });
    try std.testing.expectEqual(@as(i64, 150), delta1);
    const delta2 = state.recordUsage(.{ .input_tokens = 130, .output_tokens = 50 });
    try std.testing.expectEqual(@as(i64, 30), delta2);
}

test "recordUsage returns 0 when no goal active" {
    const alloc = std.testing.allocator;
    var state = AccountingState.init(0);
    defer state.deinit(alloc);
    const delta = state.recordUsage(.{ .input_tokens = 999, .output_tokens = 999 });
    try std.testing.expectEqual(@as(i64, 0), delta);
}

test "accountProgress accumulates and detects budget limit" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = 1000,
        .tokens_used = 800,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    defer goal.deinit(alloc);
    var outcome = try accountProgress(alloc, goal, 250, 10, 5);
    defer outcome.goal.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 1050), outcome.goal.tokens_used);
    try std.testing.expectEqual(@as(i64, 10), outcome.goal.time_used_seconds);
    try std.testing.expect(outcome.budget_limit_reached);
    try std.testing.expectEqual(goal_types.GoalStatus.budget_limited, outcome.goal.status);
}

test "accountProgress ignores budget when none set" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = null,
        .tokens_used = 999_999_999,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    defer goal.deinit(alloc);
    var outcome = try accountProgress(alloc, goal, 1000, 5, 9);
    defer outcome.goal.deinit(alloc);
    try std.testing.expect(!outcome.budget_limit_reached);
    try std.testing.expectEqual(goal_types.GoalStatus.active, outcome.goal.status);
}

test "markBudgetLimitReportedIfNew reports once" {
    const alloc = std.testing.allocator;
    var state = AccountingState.init(0);
    defer state.deinit(alloc);
    try std.testing.expect(state.markBudgetLimitReportedIfNew());
    try std.testing.expect(!state.markBudgetLimitReportedIfNew());
    state.clearActiveGoal(alloc);
    try std.testing.expect(!state.budget_limit_reported);
}

test "markGoalActive resets reported flag for new goal" {
    const alloc = std.testing.allocator;
    var state = AccountingState.init(0);
    defer state.deinit(alloc);
    try state.markGoalActive(alloc, "g1", 0);
    _ = state.markBudgetLimitReportedIfNew();
    try state.markGoalActive(alloc, "g2", 0);
    try std.testing.expect(!state.budget_limit_reported);
}
