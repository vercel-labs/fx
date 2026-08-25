const std = @import("std");
const goal_module = @import("../../core/goal/goal.zig");
const goal_types = goal_module.goal_types;
const goal_store = goal_module.goal_store;
const goal_tool = goal_module.goal_tool;
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const ToolInput = tool_dispatch.ToolInput;
const DispatchContext = tool_dispatch.DispatchContext;
const Tool = tool_dispatch.Tool;

pub const get_goal_description =
    "Get the current goal for this session, including status, budgets, token and elapsed-time usage, and remaining token budget.";

pub const create_goal_description =
    "Create a goal only when explicitly requested by the user or system/developer instructions; do not infer goals from ordinary tasks. " ++
    "Set token_budget only when an explicit token budget is requested. Fails if an unfinished goal exists; use update_goal only for status.";

pub const update_goal_description =
    "Update the existing goal. Use this tool only to mark the goal achieved or genuinely blocked. " ++
    "Set status to `complete` only when the objective has actually been achieved and no required work remains. " ++
    "Set status to `blocked` only when the same blocking condition has repeated for at least three consecutive goal turns, " ++
    "counting the original/user-triggered turn and any automatic continuations, and the agent cannot make meaningful progress without user input or an external-state change. " ++
    "Do not use `blocked` merely because the work is hard, slow, uncertain, incomplete, or would benefit from clarification. " ++
    "Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work. " ++
    "You cannot use this tool to pause, resume, budget-limit, or usage-limit a goal; those status changes are controlled by the user or system. " ++
    "When marking a budgeted goal achieved with status `complete`, report the final token usage from the tool result to the user.";

pub const get_goal = Tool{
    .name = "get_goal",
    .description = get_goal_description,
    .model_schema = .{
        .name = "get_goal",
        .description = get_goal_description,
        .input_schema = .{
            .properties = &.{},
            .additional_properties = false,
        },
    },
    .executor_kind = .get_goal,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Reading",
    .completed_action_label = "Read",
    .label_arg_kind = .none,
    .label_arg_default = "goal",
    .permission_target_kind = .none,
    .decode = decodeGet,
    .call = callGet,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

pub const create_goal = Tool{
    .name = "create_goal",
    .description = create_goal_description,
    .model_schema = .{
        .name = "create_goal",
        .description = create_goal_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "objective", .json_type = .string, .description = "Required. The concrete objective to start pursuing. This starts a new active goal when no goal exists or replaces the current goal when it is complete." },
                .{ .name = "token_budget", .json_type = .integer, .description = "Positive token budget for the new goal. Omit unless explicitly requested." },
            },
            .required = &.{"objective"},
            .additional_properties = false,
        },
    },
    .executor_kind = .create_goal,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Setting",
    .completed_action_label = "Set",
    .label_arg_kind = .description,
    .label_arg_default = "goal",
    .permission_target_kind = .none,
    .decode = decodeCreate,
    .call = callCreate,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

pub const update_goal = Tool{
    .name = "update_goal",
    .description = update_goal_description,
    .model_schema = .{
        .name = "update_goal",
        .description = update_goal_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "status", .json_type = .string, .shape = &.{ .enum_values = &.{ "complete", "blocked" } }, .description = "Required. Set to `complete` only when the objective is achieved and no required work remains. Set to `blocked` only after the same blocking condition has recurred for at least three consecutive goal turns and the agent is at an impasse." },
            },
            .required = &.{"status"},
            .additional_properties = false,
        },
    },
    .executor_kind = .update_goal,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Updating",
    .completed_action_label = "Updated",
    .label_arg_kind = .none,
    .label_arg_default = "goal",
    .permission_target_kind = .none,
    .decode = decodeUpdate,
    .call = callUpdate,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

// --- get_goal ---

const EmptyInput = struct {};

fn decodeGet(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    _ = args_json;
    const input = try ctx.allocator.create(EmptyInput);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = emptyDeinit } };
}

fn emptyDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *EmptyInput = @ptrCast(@alignCast(ptr));
    alloc.destroy(input);
}

fn callGet(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = erased;
    const goal_ctx = ctx.goal_ctx orelse return .{ .failure = try ctx.allocator.dupe(u8, "goal tools unavailable: no goal context for this session") };
    const output = goal_tool.handleGet(goal_ctx, ctx.allocator) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "get_goal failed: {s}", .{@errorName(err)}) };
    };
    return .{ .success = output };
}

// --- create_goal ---

const CreateInput = struct {
    objective: []u8,
    token_budget: ?i64,

    pub fn deinit(self: *CreateInput, alloc: Allocator) void {
        alloc.free(self.objective);
        self.* = .{ .objective = &.{}, .token_budget = null };
    }
};

fn decodeCreate(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_goal arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_goal arguments must be an object") };
    }
    const obj = parsed.value.object.get("objective") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_goal field \"objective\" is required") };
    };
    if (obj != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_goal field \"objective\" must be a string") };
    }
    const token_budget: ?i64 = blk: {
        const v = parsed.value.object.get("token_budget") orelse break :blk null;
        if (v != .integer) break :blk null;
        break :blk v.integer;
    };
    const input = try ctx.allocator.create(CreateInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .objective = try ctx.allocator.dupe(u8, obj.string),
        .token_budget = token_budget,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = createDeinit } };
}

fn createDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *CreateInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn callCreate(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(CreateInput);
    const goal_ctx = ctx.goal_ctx orelse return .{ .failure = try ctx.allocator.dupe(u8, "goal tools unavailable: no goal context for this session") };
    // Derive a per-call nonce from the goal context's now_ms mixed with the
    // pointer address of the input, which varies per invocation. This keeps
    // goal ids distinct without pulling a global RNG into the tool layer.
    const ptr_int: u64 = @intFromPtr(input);
    const rand_val: u64 = @bitCast(@as(i64, goal_ctx.now_ms) ^ @as(i64, @bitCast(ptr_int)));
    const output = goal_tool.handleCreate(goal_ctx, ctx.allocator, input.objective, input.token_budget, rand_val) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "create_goal failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

// --- update_goal ---

const UpdateInput = struct {
    status: goal_types.GoalStatus,

    pub fn deinit(self: *UpdateInput, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

fn decodeUpdate(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_goal arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_goal arguments must be an object") };
    }
    const obj = parsed.value.object.get("status") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_goal field \"status\" is required") };
    };
    if (obj != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_goal field \"status\" must be a string") };
    }
    const status = goal_types.statusFromWireStr(obj.string);
    const input = try ctx.allocator.create(UpdateInput);
    input.* = .{ .status = status };
    return .{ .input = .{ .ptr = input, .deinit_fn = updateDeinit } };
}

fn updateDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *UpdateInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn callUpdate(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(UpdateInput);
    const goal_ctx = ctx.goal_ctx orelse return .{ .failure = try ctx.allocator.dupe(u8, "goal tools unavailable: no goal context for this session") };
    const output = goal_tool.handleUpdate(goal_ctx, ctx.allocator, input.status) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "update_goal failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

fn readsOnly(_: ToolInput) bool {
    return false;
}

fn isIrreversible(_: ToolInput) bool {
    return false;
}
