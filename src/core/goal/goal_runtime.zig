const std = @import("std");
const goal_module = @import("goal.zig");
const goal_types = goal_module.goal_types;
const goal_service = goal_module.goal_service;
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub fn advanceAfterTurn(comptime App: type, app: *App, summary: types.TurnSummary) !void {
    const current = app.goal orelse return;
    const terminal_transition_pending = if (comptime @hasField(App, "goal_terminal_transition_pending_accounting"))
        app.goal_terminal_transition_pending_accounting and current.status.isTerminal()
    else
        false;
    if (current.status != .active and !terminal_transition_pending) return;
    const total_tokens = summary.token_progress.input_tokens +| summary.token_progress.output_tokens;
    const token_delta = std.math.cast(i64, total_tokens) orelse std.math.maxInt(i64);
    const persisted_remainder = std.math.cast(u64, current.time_remainder_ms) orelse 0;
    const elapsed_ms = summary.turn_duration_ms +| persisted_remainder;
    const elapsed_seconds = std.math.cast(i64, elapsed_ms / std.time.ms_per_s) orelse std.math.maxInt(i64);
    var outcome = try goal_module.goal_accounting.accountProgress(
        app.alloc,
        current,
        token_delta,
        elapsed_seconds,
        io_mod.milliTimestamp(),
    );
    defer outcome.goal.deinit(app.alloc);
    if (terminal_transition_pending) {
        outcome.goal.status = current.status;
        outcome.budget_limit_reached = false;
    }
    outcome.goal.time_remainder_ms = @intCast(elapsed_ms % std.time.ms_per_s);
    try installGoal(App, app, outcome.goal);

    if (comptime @hasField(App, "goal_terminal_transition_pending_accounting")) {
        app.goal_terminal_transition_pending_accounting = false;
    }

    if (terminal_transition_pending) return;

    if (app.worker.queuedPromptCount() != 0) return;
    const prompt = if (outcome.budget_limit_reached)
        try goal_module.goal_steering.budgetLimitPrompt(app.alloc, outcome.goal)
    else
        try goal_module.goal_steering.continuationPrompt(app.alloc, outcome.goal);
    defer app.alloc.free(prompt);
    try app.queueGoalContinuation(prompt, outcome.goal.objective);
}

pub fn replaceOwned(comptime App: type, app: *App, next: ?goal_module.goal_store.Goal) !void {
    const replacement = if (next) |goal| try goal.dupe(app.alloc) else null;
    const previous = app.goal;
    app.goal = replacement;
    app.persistGoalState() catch |err| {
        if (app.goal) |new_goal| {
            var owned = new_goal;
            owned.deinit(app.alloc);
        }
        app.goal = previous;
        return err;
    };
    if (previous) |old_goal| {
        var owned = old_goal;
        owned.deinit(app.alloc);
    }
}

/// Host-side glue for the `/goal` slash command. Parses the subcommand and
/// mutates the app's in-memory goal state via `goal_service`.
pub fn handleGoalCommand(comptime App: type, app: *App, rest: []const u8) !void {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) {
        try showGoalStatus(App, app);
        return;
    }

    if (std.mem.eql(u8, trimmed, "clear")) {
        try handleClear(App, app);
        return;
    }

    if (std.mem.eql(u8, trimmed, "pause")) {
        try handlePause(App, app);
        return;
    }

    if (std.mem.eql(u8, trimmed, "resume")) {
        try handleResume(App, app);
        return;
    }

    // Anything else is treated as a new objective.
    try handleSetObjective(App, app, trimmed);
}

fn showGoalStatus(comptime App: type, app: *App) !void {
    if (comptime @hasField(App, "goal")) {
        if (app.goal) |goal| {
            const status_label = goal.status.asStr();
            const budget_label = if (goal.token_budget) |b|
                try std.fmt.allocPrint(app.alloc, "{d} tokens", .{b})
            else
                try app.alloc.dupe(u8, "no budget");
            defer app.alloc.free(budget_label);
            const body = try std.fmt.allocPrint(app.alloc, "Goal: {s}\nStatus: {s}\nTokens used: {d} / {s}", .{
                goal.objective, status_label, goal.tokens_used, budget_label,
            });
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "goal",
                .tone = .neutral,
                .body = body,
            }, true);
            return;
        }
    }
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = "No active goal. Use /goal <objective> to set one.",
    }, true);
}

fn handleClear(comptime App: type, app: *App) !void {
    if (comptime @hasField(App, "goal")) {
        if (app.goal != null) {
            try installGoal(App, app, null);
            try app.writeDomainNotice(.{
                .topic = "goal",
                .tone = .neutral,
                .body = "Goal cleared.",
            }, true);
            return;
        }
    }
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = "No active goal to clear.",
    }, true);
}

fn handlePause(comptime App: type, app: *App) !void {
    if (comptime @hasField(App, "goal")) {
        if (app.goal) |goal| {
            if (goal.status == .active) {
                const now_ms = io_mod.milliTimestamp();
                const outcome = goal_service.set(app.alloc, goal, .{ .status = .user_paused }, now_ms, 0) catch |err| {
                    try reportServiceError(App, app, err);
                    return;
                };
                var o = outcome;
                defer o.deinit(app.alloc);
                try installGoal(App, app, o.goal);
                try app.writeDomainNotice(.{
                    .topic = "goal",
                    .tone = .neutral,
                    .body = "Goal paused. Use /goal resume to continue.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "goal",
                .tone = .neutral,
                .body = "Goal is not active; nothing to pause.",
            }, true);
            return;
        }
    }
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = "No active goal to pause.",
    }, true);
}

fn handleResume(comptime App: type, app: *App) !void {
    if (comptime @hasField(App, "goal")) {
        if (app.goal) |goal| {
            if (goal.status.isPausedOrStopped()) {
                const now_ms = io_mod.milliTimestamp();
                const outcome = goal_service.set(app.alloc, goal, .{ .status = .active }, now_ms, 0) catch |err| {
                    try reportServiceError(App, app, err);
                    return;
                };
                var o = outcome;
                defer o.deinit(app.alloc);
                try installGoal(App, app, o.goal);
                try app.writeDomainNotice(.{
                    .topic = "goal",
                    .tone = .neutral,
                    .body = "Goal resumed.",
                }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "goal",
                .tone = .neutral,
                .body = "Goal is not paused; nothing to resume.",
            }, true);
            return;
        }
    }
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = "No paused goal to resume.",
    }, true);
}

fn handleSetObjective(comptime App: type, app: *App, objective: []const u8) !void {
    goal_types.validateObjective(objective) catch |err| {
        const msg = switch (err) {
            error.ObjectiveEmpty => "Goal objective must not be empty.",
            error.ObjectiveTooLong => "Goal objective must be at most 4000 characters.",
        };
        try app.writeDomainNotice(.{
            .topic = "goal",
            .tone = .@"error",
            .body = msg,
        }, true);
        return;
    };

    const now_ms = io_mod.milliTimestamp();
    const existing = if (comptime @hasField(App, "goal")) app.goal else null;

    const outcome = goal_service.set(app.alloc, existing, .{
        .objective = objective,
    }, now_ms, @bitCast(@as(i64, now_ms))) catch |err| {
        try reportServiceError(App, app, err);
        return;
    };
    var o = outcome;
    defer o.deinit(app.alloc);

    if (comptime @hasField(App, "goal")) {
        try installGoal(App, app, o.goal);
    }

    const body = try std.fmt.allocPrint(app.alloc, "Goal set: {s}", .{objective});
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = body,
    }, true);
}

fn installGoal(comptime App: type, app: *App, goal: ?goal_module.goal_store.Goal) !void {
    if (comptime @hasDecl(App, "replaceGoal")) {
        try app.replaceGoal(goal);
        return;
    }
    const replacement = if (goal) |value| try value.dupe(app.alloc) else null;
    if (app.goal) |old_goal| {
        var old = old_goal;
        old.deinit(app.alloc);
    }
    app.goal = replacement;
}

fn reportServiceError(comptime App: type, app: *App, err: goal_service.ServiceError) !void {
    const msg = switch (err) {
        error.UnfinishedGoal => "Cannot set a new goal while an active goal exists. Complete or clear the current goal first.",
        error.NoGoal => "No active goal to update.",
        error.InvalidStatus => "Invalid goal status.",
        error.ObjectiveEmpty => "Goal objective must not be empty.",
        error.ObjectiveTooLong => "Goal objective must be at most 4000 characters.",
        error.BudgetNotPositive => "Goal token budget must be positive when provided.",
        error.BudgetExceedsMax => "Goal token budget exceeds the maximum allowed.",
        error.OutOfMemory => "Out of memory.",
    };
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .@"error",
        .body = msg,
    }, true);
}

test "turn lifecycle accounts usage, carries time, and queues budget steering" {
    const alloc = std.testing.allocator;
    const FakeWorker = struct {
        queued: usize = 0,
        fn queuedPromptCount(self: *@This()) usize {
            return self.queued;
        }
    };
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        goal: ?goal_module.goal_store.Goal,
        worker: FakeWorker = .{},
        queued_prompt: ?[]u8 = null,

        fn replaceGoal(self: *@This(), next: ?goal_module.goal_store.Goal) !void {
            const replacement = if (next) |goal| try goal.dupe(self.alloc) else null;
            if (self.goal) |old_goal| {
                var old = old_goal;
                old.deinit(self.alloc);
            }
            self.goal = replacement;
        }

        fn queueGoalContinuation(self: *@This(), prompt: []const u8, _: []const u8) !void {
            if (self.queued_prompt) |old| self.alloc.free(old);
            self.queued_prompt = try self.alloc.dupe(u8, prompt);
            self.worker.queued += 1;
        }
    };

    var app: FakeApp = .{
        .alloc = alloc,
        .goal = .{
            .goal_id = try alloc.dupe(u8, "goal-lifecycle"),
            .objective = try alloc.dupe(u8, "finish lifecycle"),
            .token_budget = 100,
            .created_at_ms = 1,
            .updated_at_ms = 1,
        },
    };
    defer {
        if (app.goal) |*goal| goal.deinit(alloc);
        if (app.queued_prompt) |prompt| alloc.free(prompt);
    }

    try advanceAfterTurn(FakeApp, &app, .{
        .turn_duration_ms = 600,
        .token_progress = .{ .input_tokens = 20, .output_tokens = 30 },
    });
    try std.testing.expectEqual(@as(i64, 50), app.goal.?.tokens_used);
    try std.testing.expectEqual(@as(i64, 0), app.goal.?.time_used_seconds);
    try std.testing.expectEqual(@as(i64, 600), app.goal.?.time_remainder_ms);
    app.worker.queued = 0;

    try advanceAfterTurn(FakeApp, &app, .{
        .turn_duration_ms = 600,
        .token_progress = .{ .input_tokens = 25, .output_tokens = 25 },
    });
    try std.testing.expectEqual(goal_types.GoalStatus.budget_limited, app.goal.?.status);
    try std.testing.expectEqual(@as(i64, 100), app.goal.?.tokens_used);
    try std.testing.expectEqual(@as(i64, 1), app.goal.?.time_used_seconds);
    try std.testing.expect(std.mem.find(u8, app.queued_prompt.?, "reached its token budget") != null);
}

test "turn lifecycle accounts the turn that completes a goal without restarting it" {
    const alloc = std.testing.allocator;
    const FakeWorker = struct {
        fn queuedPromptCount(_: *@This()) usize {
            return 0;
        }
    };
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        goal: ?goal_module.goal_store.Goal,
        worker: FakeWorker = .{},
        goal_terminal_transition_pending_accounting: bool = true,

        fn replaceGoal(self: *@This(), next: ?goal_module.goal_store.Goal) !void {
            const replacement = if (next) |goal| try goal.dupe(self.alloc) else null;
            if (self.goal) |old_goal| {
                var old = old_goal;
                old.deinit(self.alloc);
            }
            self.goal = replacement;
        }

        fn queueGoalContinuation(_: *@This(), _: []const u8, _: []const u8) !void {
            return error.UnexpectedContinuation;
        }
    };

    var app: FakeApp = .{
        .alloc = alloc,
        .goal = .{
            .goal_id = try alloc.dupe(u8, "goal-completed-turn"),
            .objective = try alloc.dupe(u8, "finish and account"),
            .status = .complete,
            .token_budget = 200,
            .created_at_ms = 1,
            .updated_at_ms = 1,
        },
    };
    defer if (app.goal) |*goal| goal.deinit(alloc);

    try advanceAfterTurn(FakeApp, &app, .{
        .turn_duration_ms = 1_200,
        .token_progress = .{ .input_tokens = 71, .output_tokens = 178 },
    });
    try std.testing.expectEqual(goal_types.GoalStatus.complete, app.goal.?.status);
    try std.testing.expectEqual(@as(i64, 249), app.goal.?.tokens_used);
    try std.testing.expectEqual(@as(i64, 1), app.goal.?.time_used_seconds);
    try std.testing.expect(!app.goal_terminal_transition_pending_accounting);
}
