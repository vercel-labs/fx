const std = @import("std");
const goal_types = @import("goal_types.zig");
const goal_store = @import("goal_store.zig");
const goal_service = @import("goal_service.zig");
const goal_accounting = @import("goal_accounting.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// Per-session goal context threaded through `DispatchContext` so the
/// stateless goal tool callbacks can read and mutate the session's goal.
/// The host owns the inner state and sets `goal` / `accounting` before each
/// turn. Tool callbacks read the current goal and return a *new* goal for the
/// host to persist; they never write to the live goal pointer directly.
pub const GoalToolContext = struct {
    /// Current goal, or null when no goal exists. Borrowed from the host.
    goal: ?goal_store.Goal = null,
    /// In-memory accounting state for budget tracking. Borrowed from the host.
    accounting: ?*goal_accounting.AccountingState = null,
    /// Wall-clock now in milliseconds at the start of this turn.
    now_ms: i64 = 0,
    /// Max allowed goal token budget, applied when a budget is omitted.
    max_goal_token_budget: ?i64 = null,
    mutation_ctx: ?*anyopaque = null,
    on_mutation: ?*const fn (?*anyopaque, goal_store.Goal) anyerror!void = null,

    fn commit(self: *GoalToolContext, goal: goal_store.Goal) !void {
        const callback = self.on_mutation orelse return error.GoalMutationUnavailable;
        try callback(self.mutation_ctx, goal);
    }
};

/// Reads the current goal (get_goal tool).
pub fn handleGet(ctx: *const GoalToolContext, alloc: Allocator) ![]u8 {
    const goal = ctx.goal orelse return jsonNullGoal(alloc);
    return jsonResponse(alloc, goal, .omit);
}

/// Creates a new goal (create_goal tool). Fails if an unfinished goal exists.
pub fn handleCreate(
    ctx: *GoalToolContext,
    alloc: Allocator,
    objective: []const u8,
    token_budget: ?i64,
    rand_u64: u64,
) ![]u8 {
    const existing = ctx.goal;
    const outcome = try goal_service.set(alloc, existing, .{
        .objective = objective,
        .token_budget = token_budget,
        .max_goal_token_budget = ctx.max_goal_token_budget,
    }, ctx.now_ms, rand_u64);
    var o = outcome;
    defer o.deinit(alloc);
    try ctx.commit(o.goal);
    return jsonResponse(alloc, o.goal, .omit);
}

/// Marks the existing goal complete or blocked (update_goal tool).
pub fn handleUpdate(
    ctx: *GoalToolContext,
    alloc: Allocator,
    status: goal_types.GoalStatus,
) ![]u8 {
    if (status != .complete and status != .blocked) {
        return error.InvalidStatus;
    }
    const existing = ctx.goal orelse return error.NoGoal;
    const outcome = try goal_service.set(alloc, existing, .{ .status = status }, ctx.now_ms, 0);
    var o = outcome;
    defer o.deinit(alloc);
    try ctx.commit(o.goal);
    const report: ReportMode = if (status == .complete) .include else .omit;
    return jsonResponse(alloc, o.goal, report);
}

const ReportMode = enum { include, omit };

fn jsonResponse(alloc: Allocator, goal: goal_store.Goal, report: ReportMode) ![]u8 {
    const goal_json = try goal_store.toJson(alloc, goal);
    defer alloc.free(goal_json);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"goal\":");
    try out.writer.writeAll(goal_json);
    const remaining = if (goal.token_budget) |b|
        (if (b > goal.tokens_used) b - goal.tokens_used else 0)
    else
        null;
    if (remaining) |r| {
        try out.writer.print(",\"remaining_tokens\":{d}", .{r});
    } else {
        try out.writer.writeAll(",\"remaining_tokens\":null");
    }
    if (report == .include and goal.status == .complete) {
        try out.writer.writeAll(",\"completion_budget_report\":\"Goal achieved. This tool result contains usage through prior finalized turns; the host accounts the current turn after the response finishes. Do not describe this value as final current-turn usage.\"");
    }
    try out.writer.writeAll("}");
    return try out.toOwnedSlice();
}

fn jsonNullGoal(alloc: Allocator) ![]u8 {
    const s = "{\"goal\":null,\"remaining_tokens\":null}";
    return alloc.dupe(u8, s);
}

test "handleGet returns null goal when none exists" {
    const alloc = std.testing.allocator;
    const ctx: GoalToolContext = .{};
    const out = try handleGet(&ctx, alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"goal\":null,\"remaining_tokens\":null}", out);
}

test "handleGet returns goal json when present" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = 1000,
        .tokens_used = 200,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    const ctx: GoalToolContext = .{ .goal = goal };
    const out = try handleGet(&ctx, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"goal_id\":\"g1\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"remaining_tokens\":800") != null);
}

test "handleCreate rejects an empty objective" {
    const alloc = std.testing.allocator;
    var ctx: GoalToolContext = .{};
    try std.testing.expectError(error.ObjectiveEmpty, handleCreate(&ctx, alloc, "  ", null, 0x1));
}

test "handleCreate returns goal json on success" {
    const alloc = std.testing.allocator;
    var ctx: GoalToolContext = .{ .now_ms = 10, .on_mutation = discardTestMutation };
    const out = try handleCreate(&ctx, alloc, "ship the release", 500, 0x1);
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "ship the release") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"status\":\"active\"") != null);
}

test "handleUpdate rejects a missing goal" {
    const alloc = std.testing.allocator;
    var ctx: GoalToolContext = .{};
    try std.testing.expectError(error.NoGoal, handleUpdate(&ctx, alloc, .complete));
}

test "handleUpdate returns error for invalid status" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    var ctx: GoalToolContext = .{ .goal = goal };
    try std.testing.expectError(error.InvalidStatus, handleUpdate(&ctx, alloc, .active));
}

test "handleUpdate marks complete with budget report" {
    const alloc = std.testing.allocator;
    var goal: goal_store.Goal = .{
        .goal_id = try alloc.dupe(u8, "g1"),
        .objective = try alloc.dupe(u8, "ship it"),
        .token_budget = 1000,
        .tokens_used = 800,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
    defer goal.deinit(alloc);
    var ctx: GoalToolContext = .{ .goal = goal, .now_ms = 5, .on_mutation = discardTestMutation };
    const out = try handleUpdate(&ctx, alloc, .complete);
    defer alloc.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"status\":\"complete\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "completion_budget_report") != null);
}

fn discardTestMutation(_: ?*anyopaque, _: goal_store.Goal) anyerror!void {}
