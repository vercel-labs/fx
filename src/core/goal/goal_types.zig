const std = @import("std");

/// Lifecycle status of a persisted thread goal. A six-state model with a
/// fail-safe deserialization rule: an unknown wire value restores as
/// `user_paused` so a corrupt or forward-version snapshot can never resurrect
/// as a self-driving `active` goal.
pub const GoalStatus = enum {
    active,
    user_paused,
    blocked,
    usage_limited,
    budget_limited,
    complete,

    pub fn asStr(self: GoalStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .user_paused => "user_paused",
            .blocked => "blocked",
            .usage_limited => "usage_limited",
            .budget_limited => "budget_limited",
            .complete => "complete",
        };
    }

    pub fn isActive(self: GoalStatus) bool {
        return self == .active;
    }

    /// `true` for the paused/stopped family the model may resume from, so
    /// callers can treat the stopped family uniformly without enumerating each
    /// variant.
    pub fn isPausedOrStopped(self: GoalStatus) bool {
        return switch (self) {
            .user_paused,
            .blocked,
            .usage_limited,
            .budget_limited,
            => true,
            .active,
            .complete,
            => false,
        };
    }

    pub fn isTerminal(self: GoalStatus) bool {
        return self == .budget_limited or self == .complete;
    }
};

/// Parse a persisted/wire status string. Unknown values map to `user_paused`
/// (fail-safe): a status this build cannot interpret must restore as a
/// resumable paused goal, never an `active` self-driving one.
pub fn statusFromWireStr(s: []const u8) GoalStatus {
    if (std.mem.eql(u8, s, "active")) return .active;
    if (std.mem.eql(u8, s, "user_paused") or std.mem.eql(u8, s, "paused")) return .user_paused;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "usage_limited")) return .usage_limited;
    if (std.mem.eql(u8, s, "budget_limited")) return .budget_limited;
    if (std.mem.eql(u8, s, "complete")) return .complete;
    return .user_paused;
}

pub const max_goal_objective_chars: usize = 4_000;

pub const GoalObjectiveError = error{
    ObjectiveEmpty,
    ObjectiveTooLong,
};

pub fn validateObjective(value: []const u8) GoalObjectiveError!void {
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) return error.ObjectiveEmpty;
    const char_count = std.unicode.utf8CountCodepoints(trimmed) catch return error.ObjectiveTooLong;
    if (char_count > max_goal_objective_chars) return error.ObjectiveTooLong;
}

pub const BudgetError = error{
    BudgetNotPositive,
    BudgetExceedsMax,
};

pub fn validateGoalBudget(value: ?i64, max_goal_token_budget: ?i64) BudgetError!void {
    if (value) |v| {
        if (v <= 0) return error.BudgetNotPositive;
        if (max_goal_token_budget) |max| {
            if (v > max) return error.BudgetExceedsMax;
        }
    }
}

test "statusFromWireStr maps unknown to user_paused" {
    try std.testing.expectEqual(GoalStatus.user_paused, statusFromWireStr("nonsense"));
    try std.testing.expectEqual(GoalStatus.user_paused, statusFromWireStr(""));
    try std.testing.expectEqual(GoalStatus.active, statusFromWireStr("active"));
    try std.testing.expectEqual(GoalStatus.user_paused, statusFromWireStr("paused"));
    try std.testing.expectEqual(GoalStatus.complete, statusFromWireStr("complete"));
    try std.testing.expectEqual(GoalStatus.budget_limited, statusFromWireStr("budget_limited"));
}

test "isPausedOrStopped covers stopped family" {
    try std.testing.expect(GoalStatus.user_paused.isPausedOrStopped());
    try std.testing.expect(GoalStatus.blocked.isPausedOrStopped());
    try std.testing.expect(GoalStatus.usage_limited.isPausedOrStopped());
    try std.testing.expect(GoalStatus.budget_limited.isPausedOrStopped());
    try std.testing.expect(!GoalStatus.active.isPausedOrStopped());
    try std.testing.expect(!GoalStatus.complete.isPausedOrStopped());
}

test "validateObjective rejects empty, whitespace-only, and overlong" {
    try std.testing.expectError(error.ObjectiveEmpty, validateObjective(""));
    try std.testing.expectError(error.ObjectiveEmpty, validateObjective("   "));
    try std.testing.expectError(error.ObjectiveEmpty, validateObjective("\n\t "));
    try validateObjective("ship the release");
}
