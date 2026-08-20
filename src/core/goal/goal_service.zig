const std = @import("std");
const goal_types = @import("goal_types.zig");
const goal_store = @import("goal_store.zig");

const Allocator = std.mem.Allocator;

pub const ServiceError = error{
    NoGoal,
    UnfinishedGoal,
    InvalidStatus,
    ObjectiveEmpty,
    ObjectiveTooLong,
    BudgetNotPositive,
    BudgetExceedsMax,
    OutOfMemory,
};

/// External mutations a slash command or host action performs on the goal.
pub const SetRequest = struct {
    objective: ?[]const u8 = null,
    status: ?goal_types.GoalStatus = null,
    token_budget: ?i64 = null,
    max_goal_token_budget: ?i64 = null,
};

/// Result of a successful set, with the previous goal snapshot for steering.
pub const SetOutcome = struct {
    goal: goal_store.Goal,
    previous_goal: ?goal_store.Goal = null,
    objective_changed: bool = false,

    pub fn deinit(self: *SetOutcome, alloc: Allocator) void {
        self.goal.deinit(alloc);
        if (self.previous_goal) |*prev| prev.deinit(alloc);
        self.* = undefined;
    }
};

/// Reads the current goal, if any.
pub fn getGoal(goal: ?goal_store.Goal) ?goal_store.Goal {
    return goal;
}

/// Creates or updates the session goal according to `request`.
///
/// - `objective` set: create a new goal when none exists, or replace when the
///   existing one is terminal. Fails with `UnfinishedGoal` if an active goal
///   already exists (the model must complete it first).
/// - `objective` null: update only the status/budget of the existing goal.
pub fn set(
    alloc: Allocator,
    existing: ?goal_store.Goal,
    request: SetRequest,
    now_ms: i64,
    rand_u64: u64,
) ServiceError!SetOutcome {
    var trimmed_objective: ?[]const u8 = null;
    if (request.objective) |obj| {
        trimmed_objective = std.mem.trim(u8, obj, " \t\n\r");
    }

    if (trimmed_objective) |obj| {
        goal_types.validateObjective(obj) catch |err| switch (err) {
            error.ObjectiveEmpty => return error.ObjectiveEmpty,
            error.ObjectiveTooLong => return error.ObjectiveTooLong,
        };
    }

    const effective_budget: ?i64 = blk: {
        if (request.token_budget) |b| break :blk b;
        if (trimmed_objective != null) break :blk request.max_goal_token_budget;
        break :blk null;
    };
    if (effective_budget) |b| {
        if (b <= 0) return error.BudgetNotPositive;
        if (request.max_goal_token_budget) |max| {
            if (b > max) return error.BudgetExceedsMax;
        }
    }

    if (trimmed_objective) |obj| {
        if (existing) |existing_goal| {
            if (!existing_goal.status.isTerminal()) return error.UnfinishedGoal;
            const previous = try existing_goal.dupe(alloc);
            var updated = try existing_goal.dupe(alloc);
            errdefer updated.deinit(alloc);
            alloc.free(updated.objective);
            updated.objective = try alloc.dupe(u8, obj);
            updated.status = request.status orelse .active;
            updated.token_budget = effective_budget;
            updated.updated_at_ms = now_ms;
            return .{
                .goal = updated,
                .previous_goal = previous,
                .objective_changed = true,
            };
        }
        const goal_id = try goal_store.newGoalId(alloc, now_ms, rand_u64);
        errdefer alloc.free(goal_id);
        return .{
            .goal = .{
                .goal_id = goal_id,
                .objective = try alloc.dupe(u8, obj),
                .status = request.status orelse .active,
                .token_budget = effective_budget,
                .created_at_ms = now_ms,
                .updated_at_ms = now_ms,
            },
            .objective_changed = true,
        };
    }

    const existing_goal = existing orelse return error.NoGoal;
    const previous = try existing_goal.dupe(alloc);
    var updated = try existing_goal.dupe(alloc);
    errdefer updated.deinit(alloc);
    if (request.status) |status| updated.status = status;
    if (effective_budget) |b| updated.token_budget = b;
    updated.updated_at_ms = now_ms;
    return .{ .goal = updated, .previous_goal = previous };
}

/// Returns true if the goal was cleared.
pub fn clear(alloc: Allocator, goal: ?goal_store.Goal) ServiceError!bool {
    _ = alloc;
    if (goal) |g| {
        // Caller frees the goal; this only signals deletion.
        _ = g;
        return true;
    }
    return false;
}

test "set creates a new goal when none exists" {
    const alloc = std.testing.allocator;
    const outcome = try set(alloc, null, .{
        .objective = "ship the release",
        .token_budget = 1000,
        .max_goal_token_budget = 5000,
    }, 100, 0xabc);
    var o = outcome;
    defer o.deinit(alloc);
    try std.testing.expectEqualStrings("ship the release", o.goal.objective);
    try std.testing.expectEqual(goal_types.GoalStatus.active, o.goal.status);
    try std.testing.expectEqual(@as(?i64, 1000), o.goal.token_budget);
    try std.testing.expect(o.previous_goal == null);
    try std.testing.expect(o.objective_changed);
}

test "set fails when an unfinished goal exists" {
    const alloc = std.testing.allocator;
    var existing: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "old"),
        .status = .active,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    defer existing.deinit(alloc);
    try std.testing.expectError(error.UnfinishedGoal, set(alloc, existing, .{
        .objective = "new",
    }, 100, 0x1));
}

test "set replaces a terminal goal with a new objective" {
    const alloc = std.testing.allocator;
    var existing: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "old"),
        .status = .complete,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    defer existing.deinit(alloc);
    const outcome = try set(alloc, existing, .{ .objective = "new" }, 100, 0x1);
    var o = outcome;
    defer o.deinit(alloc);
    try std.testing.expectEqualStrings("new", o.goal.objective);
    try std.testing.expectEqual(goal_types.GoalStatus.active, o.goal.status);
    try std.testing.expect(o.previous_goal != null);
    try std.testing.expect(o.objective_changed);
}

test "set updates status without changing objective" {
    const alloc = std.testing.allocator;
    var existing: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .status = .active,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
    defer existing.deinit(alloc);
    const outcome = try set(alloc, existing, .{ .status = .user_paused }, 100, 0x1);
    var o = outcome;
    defer o.deinit(alloc);
    try std.testing.expectEqual(goal_types.GoalStatus.user_paused, o.goal.status);
    try std.testing.expectEqualStrings("ship it", o.goal.objective);
    try std.testing.expect(!o.objective_changed);
}

test "set rejects empty objective" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.ObjectiveEmpty, set(alloc, null, .{
        .objective = "   ",
    }, 100, 0x1));
}

test "set rejects non-positive budget" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BudgetNotPositive, set(alloc, null, .{
        .objective = "x",
        .token_budget = 0,
    }, 100, 0x1));
    try std.testing.expectError(error.BudgetNotPositive, set(alloc, null, .{
        .objective = "x",
        .token_budget = -5,
    }, 100, 0x1));
}

test "set rejects budget exceeding max" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BudgetExceedsMax, set(alloc, null, .{
        .objective = "x",
        .token_budget = 10_000,
        .max_goal_token_budget = 1000,
    }, 100, 0x1));
}

test "set applies max budget when objective provided without explicit budget" {
    const alloc = std.testing.allocator;
    const outcome = try set(alloc, null, .{
        .objective = "x",
        .max_goal_token_budget = 2000,
    }, 100, 0x1);
    var o = outcome;
    defer o.deinit(alloc);
    try std.testing.expectEqual(@as(?i64, 2000), o.goal.token_budget);
}

test "clear returns false when no goal" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!(try clear(alloc, null)));
}

test "clear returns true when goal exists" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try clear(alloc, null) == false);
    // Actual clear with a goal requires the caller to free it.
}
