const std = @import("std");
const goal_types = @import("goal_types.zig");

const Allocator = std.mem.Allocator;

/// A persisted thread goal. One per session, embedded in `DurableSessionState`.
pub const Goal = struct {
    goal_id: []u8,
    objective: []u8,
    status: goal_types.GoalStatus = .active,
    token_budget: ?i64 = null,
    tokens_used: i64 = 0,
    time_used_seconds: i64 = 0,
    time_remainder_ms: i64 = 0,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Goal, alloc: Allocator) void {
        alloc.free(self.goal_id);
        alloc.free(self.objective);
        self.* = undefined;
    }

    pub fn dupe(self: Goal, alloc: Allocator) !Goal {
        const goal_id = try alloc.dupe(u8, self.goal_id);
        errdefer alloc.free(goal_id);
        const objective = try alloc.dupe(u8, self.objective);
        return .{
            .goal_id = goal_id,
            .objective = objective,
            .status = self.status,
            .token_budget = self.token_budget,
            .tokens_used = self.tokens_used,
            .time_used_seconds = self.time_used_seconds,
            .time_remainder_ms = self.time_remainder_ms,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }
};

test "Goal dupe is independently owned" {
    const alloc = std.testing.allocator;
    var goal: Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    var copy = try goal.dupe(alloc);
    defer copy.deinit(alloc);
    try std.testing.expectEqualStrings("g1", copy.goal_id);
    try std.testing.expect(copy.goal_id.ptr != goal.goal_id.ptr);
}

/// Allocates a new opaque goal id of the form `goal_<ms>_<rand>`.
pub fn newGoalId(alloc: Allocator, now_ms: i64, rand_u64: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "goal_{d}_{x}", .{ now_ms, rand_u64 });
}

/// Serializes a goal to a JSON object string. The caller owns the result.
pub fn toJson(alloc: Allocator, goal: Goal) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJson(&out.writer, goal);
    return try out.toOwnedSlice();
}

pub fn writeJson(writer: *std.Io.Writer, goal: Goal) !void {
    try writer.writeAll("{\"goal_id\":");
    try std.json.Stringify.value(goal.goal_id, .{}, writer);
    try writer.writeAll(",\"objective\":");
    try std.json.Stringify.value(goal.objective, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(goal.status.asStr(), .{}, writer);
    if (goal.token_budget) |budget| {
        try writer.print(",\"token_budget\":{d}", .{budget});
    } else {
        try writer.writeAll(",\"token_budget\":null");
    }
    try writer.print(",\"tokens_used\":{d}", .{goal.tokens_used});
    try writer.print(",\"time_used_seconds\":{d}", .{goal.time_used_seconds});
    try writer.print(",\"time_remainder_ms\":{d}", .{goal.time_remainder_ms});
    try writer.print(",\"created_at_ms\":{d}", .{goal.created_at_ms});
    try writer.print(",\"updated_at_ms\":{d}", .{goal.updated_at_ms});
    try writer.writeAll("}");
}

/// Parses a goal from a JSON value object. Caller owns the returned goal.
pub fn fromJson(alloc: Allocator, obj: std.json.Value) !Goal {
    if (obj != .object) return error.InvalidGoalJson;
    const goal_id_v = obj.object.get("goal_id") orelse return error.InvalidGoalJson;
    const objective_v = obj.object.get("objective") orelse return error.InvalidGoalJson;
    if (goal_id_v != .string or objective_v != .string) return error.InvalidGoalJson;
    const status_v = obj.object.get("status") orelse return error.InvalidGoalJson;
    if (status_v != .string) return error.InvalidGoalJson;
    const token_budget_v = obj.object.get("token_budget") orelse return error.InvalidGoalJson;
    const token_budget: ?i64 = switch (token_budget_v) {
        .integer, .number_string => try parseInteger(token_budget_v),
        .null => null,
        else => return error.InvalidGoalJson,
    };
    const tokens_used = try requiredNonNegativeInteger(obj, "tokens_used");
    const time_used_seconds = try requiredNonNegativeInteger(obj, "time_used_seconds");
    const time_remainder_ms = if (obj.object.get("time_remainder_ms")) |value|
        try nonNegativeInteger(value)
    else
        0;
    if (time_remainder_ms >= std.time.ms_per_s) return error.InvalidGoalJson;
    const created_at_ms = try requiredNonNegativeInteger(obj, "created_at_ms");
    const updated_at_ms = try requiredNonNegativeInteger(obj, "updated_at_ms");
    if (token_budget) |budget| if (budget <= 0) return error.InvalidGoalJson;
    const goal_id = try alloc.dupe(u8, goal_id_v.string);
    errdefer alloc.free(goal_id);
    const objective = try alloc.dupe(u8, objective_v.string);
    return .{
        .goal_id = goal_id,
        .objective = objective,
        .status = goal_types.statusFromWireStr(status_v.string),
        .token_budget = token_budget,
        .tokens_used = tokens_used,
        .time_used_seconds = time_used_seconds,
        .time_remainder_ms = time_remainder_ms,
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
    };
}

fn requiredNonNegativeInteger(obj: std.json.Value, key: []const u8) !i64 {
    const value = obj.object.get(key) orelse return error.InvalidGoalJson;
    return nonNegativeInteger(value);
}

fn nonNegativeInteger(value: std.json.Value) !i64 {
    const parsed = try parseInteger(value);
    if (parsed < 0) return error.InvalidGoalJson;
    return parsed;
}

fn parseInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidGoalJson,
        else => error.InvalidGoalJson,
    };
}

test "toJson and fromJson round-trip preserves fields" {
    const alloc = std.testing.allocator;
    var goal: Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship \"it\" & <go>"),
        .status = .budget_limited,
        .token_budget = 1000,
        .tokens_used = 750,
        .time_used_seconds = 42,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const json = try toJson(alloc, goal);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var restored = try fromJson(alloc, parsed.value);
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings("g1", restored.goal_id);
    try std.testing.expectEqualStrings("ship \"it\" & <go>", restored.objective);
    try std.testing.expectEqual(goal_types.GoalStatus.budget_limited, restored.status);
    try std.testing.expectEqual(@as(?i64, 1000), restored.token_budget);
    try std.testing.expectEqual(@as(i64, 750), restored.tokens_used);
    try std.testing.expectEqual(@as(i64, 42), restored.time_used_seconds);
}

test "fromJson maps unknown status to user_paused" {
    const alloc = std.testing.allocator;
    const json = "{\"goal_id\":\"g\",\"objective\":\"x\",\"status\":\"future_status\",\"token_budget\":null,\"tokens_used\":0,\"time_used_seconds\":0,\"time_remainder_ms\":0,\"created_at_ms\":0,\"updated_at_ms\":0}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var restored = try fromJson(alloc, parsed.value);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(goal_types.GoalStatus.user_paused, restored.status);
}
