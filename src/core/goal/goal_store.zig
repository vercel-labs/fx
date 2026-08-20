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
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Goal, alloc: Allocator) void {
        alloc.free(self.goal_id);
        alloc.free(self.objective);
        self.* = undefined;
    }

    pub fn dupe(self: Goal, alloc: Allocator) !Goal {
        return .{
            .goal_id = try alloc.dupe(u8, self.goal_id),
            .objective = try alloc.dupe(u8, self.objective),
            .status = self.status,
            .token_budget = self.token_budget,
            .tokens_used = self.tokens_used,
            .time_used_seconds = self.time_used_seconds,
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
    try out.writer.writeAll("{");
    try writeJsonStr(&out.writer, "goal_id");
    try out.writer.writeAll(":");
    try writeJsonStr(&out.writer, goal.goal_id);
    try out.writer.writeAll(",");
    try writeJsonStr(&out.writer, "objective");
    try out.writer.writeAll(":");
    try writeJsonStr(&out.writer, goal.objective);
    try out.writer.print(",\"status\":\"{s}\",", .{goal.status.asStr()});
    if (goal.token_budget) |budget| {
        try out.writer.print("\"token_budget\":{d},", .{budget});
    } else {
        try out.writer.writeAll("\"token_budget\":null,");
    }
    try out.writer.print("\"tokens_used\":{d},", .{goal.tokens_used});
    try out.writer.print("\"time_used_seconds\":{d},", .{goal.time_used_seconds});
    try out.writer.print("\"created_at_ms\":{d},", .{goal.created_at_ms});
    try out.writer.print("\"updated_at_ms\":{d}", .{goal.updated_at_ms});
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

fn writeJsonStr(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}

/// Parses a goal from a JSON value object. Caller owns the returned goal.
pub fn fromJson(alloc: Allocator, obj: std.json.Value) !Goal {
    if (obj != .object) return error.InvalidGoalJson;
    const goal_id_v = obj.object.get("goal_id") orelse return error.InvalidGoalJson;
    const objective_v = obj.object.get("objective") orelse return error.InvalidGoalJson;
    if (goal_id_v != .string or objective_v != .string) return error.InvalidGoalJson;
    const status_str = if (obj.object.get("status")) |s| (if (s == .string) s.string else "user_paused") else "user_paused";
    const token_budget: ?i64 = if (obj.object.get("token_budget")) |v| switch (v) {
        .integer => |i| i,
        .null => null,
        else => null,
    } else null;
    const tokens_used: i64 = if (obj.object.get("tokens_used")) |v| (if (v == .integer) v.integer else 0) else 0;
    const time_used_seconds: i64 = if (obj.object.get("time_used_seconds")) |v| (if (v == .integer) v.integer else 0) else 0;
    const created_at_ms: i64 = if (obj.object.get("created_at_ms")) |v| (if (v == .integer) v.integer else 0) else 0;
    const updated_at_ms: i64 = if (obj.object.get("updated_at_ms")) |v| (if (v == .integer) v.integer else 0) else 0;
    return .{
        .goal_id = try alloc.dupe(u8, goal_id_v.string),
        .objective = try alloc.dupe(u8, objective_v.string),
        .status = goal_types.statusFromWireStr(status_str),
        .token_budget = token_budget,
        .tokens_used = tokens_used,
        .time_used_seconds = time_used_seconds,
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
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
    const json = "{\"goal_id\":\"g\",\"objective\":\"x\",\"status\":\"future_status\",\"tokens_used\":0,\"time_used_seconds\":0,\"created_at_ms\":0,\"updated_at_ms\":0}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var restored = try fromJson(alloc, parsed.value);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(goal_types.GoalStatus.user_paused, restored.status);
}
