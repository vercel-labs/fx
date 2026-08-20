const std = @import("std");
const goal_module = @import("goal.zig");
const goal_types = goal_module.goal_types;
const goal_store = goal_module.goal_store;
const goal_service = goal_module.goal_service;
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Host-side glue for the `/goal` slash command. Parses the subcommand and
/// renders a domain notice. The live session goal is read from the app's goal
/// state when available; until that wiring lands, this surfaces the goal
/// status and subcommand syntax.
pub fn handleGoalCommand(comptime App: type, app: *App, rest: []const u8) !void {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) {
        try showGoalStatus(App, app);
        return;
    }

    if (std.mem.eql(u8, trimmed, "clear")) {
        try app.writeDomainNotice(.{
            .topic = "goal",
            .tone = .neutral,
            .body = "No active goal to clear.",
        }, true);
        return;
    }

    if (std.mem.eql(u8, trimmed, "pause")) {
        try app.writeDomainNotice(.{
            .topic = "goal",
            .tone = .neutral,
            .body = "No active goal to pause.",
        }, true);
        return;
    }

    if (std.mem.eql(u8, trimmed, "resume")) {
        try app.writeDomainNotice(.{
            .topic = "goal",
            .tone = .neutral,
            .body = "No paused goal to resume.",
        }, true);
        return;
    }

    // Anything else is treated as a new objective.
    goal_types.validateObjective(trimmed) catch |err| {
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

    const body = try std.fmt.allocPrint(app.alloc, "Goal set: {s}", .{trimmed});
    defer app.alloc.free(body);
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = body,
    }, true);
}

fn showGoalStatus(comptime App: type, app: *App) !void {
    try app.writeDomainNotice(.{
        .topic = "goal",
        .tone = .neutral,
        .body = "No active goal. Use /goal <objective> to set one.",
    }, true);
}
