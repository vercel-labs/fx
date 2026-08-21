const std = @import("std");
const goal_module = @import("goal.zig");
const goal_types = goal_module.goal_types;
const goal_service = goal_module.goal_service;
const io_mod = @import("../shared/io.zig");

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
        if (app.goal) |goal| {
            var g = goal;
            g.deinit(app.alloc);
            app.goal = null;
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
                var old = goal;
                old.deinit(app.alloc);
                app.goal = try o.goal.dupe(app.alloc);
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
                var old = goal;
                old.deinit(app.alloc);
                app.goal = try o.goal.dupe(app.alloc);
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
        if (app.goal) |old| {
            var g = old;
            g.deinit(app.alloc);
        }
        app.goal = try o.goal.dupe(app.alloc);
    }

    const body = try std.fmt.allocPrint(app.alloc, "Goal set: {s}", .{objective});
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = body,
    }, true);
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
