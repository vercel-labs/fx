const std = @import("std");
const command_admission = @import("command_admission.zig");
const core_types = @import("../shared/types.zig");

/// Permission mode threaded through core tool dispatch.
pub const PermissionMode = core_types.PermissionMode;

/// Action selected by the core permission gate.
pub const Action = enum {
    allow,
    deny,
    ask,
};

pub const PermissionDecisionError = error{
    OutOfMemory,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

/// Pure permission decision with a human-readable reason.
pub const Decision = struct {
    action: Action,
    reason: []const u8,
    reason_owned: bool = false,
    denial_reason: ?core_types.ToolPermissionDenialReason = null,
    structured_model_output: bool = false,
    // Single-grant behavior is unchanged; suggestions are additive metadata.
    grant_suggestions: []core_types.PermissionGrant = &.{},
    grant_suggestions_owned: bool = false,
    grant_suggestions_alloc: ?std.mem.Allocator = null,
    execution_authority: ?command_admission.ToolExecutionAuthority = null,
    authority_owned_cwd: ?[]u8 = null,

    pub fn deinit(self: *Decision, alloc: std.mem.Allocator) void {
        if (self.reason_owned) alloc.free(self.reason);
        if (self.grant_suggestions_owned) {
            core_types.freePermissionGrantSlice(self.grant_suggestions_alloc orelse alloc, self.grant_suggestions);
        }
        if (self.authority_owned_cwd) |cwd| alloc.free(cwd);
        self.* = undefined;
    }
};

fn requireDecisionShape(
    comptime ToolPtr: type,
    comptime Input: type,
    comptime Ctx: type,
    comptime Return: type,
) void {
    const Tool = switch (@typeInfo(ToolPtr)) {
        .pointer => |ptr| ptr.child,
        else => @compileError("permission gate expects a pointer to a tool descriptor"),
    };

    if (!@hasField(Tool, "reads_only_fn")) @compileError("permission gate tool must expose reads_only_fn");
    if (!@hasField(Tool, "irreversible_fn")) @compileError("permission gate tool must expose irreversible_fn");
    if (!@hasField(Ctx, "permission_decider")) @compileError("permission gate context must expose permission_decider");

    const reads_only_type = @TypeOf(@field(@as(Tool, undefined), "reads_only_fn"));
    const irreversible_type = @TypeOf(@field(@as(Tool, undefined), "irreversible_fn"));
    const decider_type = @TypeOf(@field(@as(Ctx, undefined), "permission_decider"));

    if (reads_only_type != *const fn (Input) bool) @compileError("permission gate reads_only_fn has an unexpected signature");
    if (irreversible_type != *const fn (Input) bool) @compileError("permission gate irreversible_fn has an unexpected signature");
    if (decider_type != ?*const fn (ToolPtr, Input, Ctx) Return) @compileError("permission gate decider has an unexpected signature");
}

fn yoloDecision() Decision {
    return .{
        .action = .allow,
        .reason = "allowed by yolo mode",
    };
}

fn fallbackDecision(tool: anytype, input: anytype) Decision {
    if (!tool.reads_only_fn(input)) {
        return .{
            .action = .deny,
            .reason = "tool invocation is not read-only",
            .denial_reason = .permission_required,
        };
    }
    if (tool.irreversible_fn(input)) {
        return .{
            .action = .deny,
            .reason = "tool invocation is irreversible",
            .denial_reason = .permission_required,
        };
    }
    return .{
        .action = .allow,
        .reason = "read-only invocation allowed",
    };
}

/// Decides an ordinary typed-tool invocation without an operational error edge.
pub fn decideOrdinary(tool: anytype, input: anytype, ctx: anytype) Decision {
    comptime requireDecisionShape(@TypeOf(tool), @TypeOf(input), @TypeOf(ctx), Decision);

    if (ctx.permission_mode == .yolo) return yoloDecision();
    if (ctx.permission_decider) |decider| return decider(tool, input, ctx);
    return fallbackDecision(tool, input);
}

/// Decides a run-dispatch invocation while preserving policy I/O failures.
pub fn decide(tool: anytype, input: anytype, ctx: anytype) PermissionDecisionError!Decision {
    comptime requireDecisionShape(
        @TypeOf(tool),
        @TypeOf(input),
        @TypeOf(ctx),
        PermissionDecisionError!Decision,
    );

    if (ctx.permission_mode == .yolo) return yoloDecision();
    if (ctx.permission_decider) |decider| return decider(tool, input, ctx);
    return fallbackDecision(tool, input);
}

const MockInput = struct {
    read_only: bool = true,
    destructive: bool = false,
};

const MockTool = struct {
    reads_only_fn: *const fn (MockInput) bool = mockReadsOnly,
    irreversible_fn: *const fn (MockInput) bool = mockIrreversible,

    fn mockReadsOnly(input: MockInput) bool {
        return input.read_only;
    }

    fn mockIrreversible(input: MockInput) bool {
        return input.destructive;
    }
};

const MockContext = struct {
    permission_mode: PermissionMode,
    permission_decider: ?*const fn (*const MockTool, MockInput, MockContext) Decision = null,
};

test "decide allows read-only non-destructive invocation in ask mode" {
    const tool = MockTool{};
    const decision = decideOrdinary(&tool, MockInput{}, MockContext{ .permission_mode = .ask });

    try std.testing.expectEqual(.allow, decision.action);
    try std.testing.expectEqualStrings("read-only invocation allowed", decision.reason);
}

test "decide allows read-only non-destructive invocation in auto mode" {
    const tool = MockTool{};
    const decision = decideOrdinary(&tool, MockInput{}, MockContext{ .permission_mode = .auto });

    try std.testing.expectEqual(.allow, decision.action);
}

test "decide denies non-read-only invocation" {
    const tool = MockTool{};
    const decision = decideOrdinary(&tool, MockInput{ .read_only = false }, MockContext{ .permission_mode = .ask });

    try std.testing.expectEqual(.deny, decision.action);
    try std.testing.expectEqualStrings("tool invocation is not read-only", decision.reason);
}

test "decide denies irreversible invocation" {
    const tool = MockTool{};
    const decision = decideOrdinary(&tool, MockInput{ .destructive = true }, MockContext{ .permission_mode = .auto });

    try std.testing.expectEqual(.deny, decision.action);
    try std.testing.expectEqualStrings("tool invocation is irreversible", decision.reason);
}

test "decide allows irreversible invocation in yolo mode without consulting a decider" {
    const tool = MockTool{};
    const decision = decideOrdinary(
        &tool,
        MockInput{ .read_only = false, .destructive = true },
        MockContext{
            .permission_mode = .yolo,
            .permission_decider = struct {
                fn deny(_: *const MockTool, _: MockInput, _: MockContext) Decision {
                    return .{ .action = .deny, .reason = "must not be called" };
                }
            }.deny,
        },
    );

    try std.testing.expectEqual(.allow, decision.action);
    try std.testing.expectEqualStrings("allowed by yolo mode", decision.reason);
}

test "Decision deinit leaves static reason and grant suggestions alone" {
    var decision = Decision{
        .action = .allow,
        .reason = "allowed",
    };
    decision.deinit(std.testing.allocator);
}

test "Decision deinit frees owned grant suggestions" {
    const alloc = std.testing.allocator;
    var grants = try alloc.alloc(core_types.PermissionGrant, 1);
    errdefer alloc.free(grants);

    const tool_name = try alloc.dupe(u8, "bash");
    errdefer alloc.free(tool_name);
    const target_path = try alloc.dupe(u8, "npm*");
    errdefer alloc.free(target_path);

    grants[0] = .{
        .shell_epoch = 0,
        .tool_name = tool_name,
        .target_path = target_path,
    };

    var decision = Decision{
        .action = .deny,
        .reason = "denied",
        .grant_suggestions = grants,
        .grant_suggestions_owned = true,
        .grant_suggestions_alloc = alloc,
    };
    decision.deinit(alloc);
}

var injected_permission_error: PermissionDecisionError = error.OutOfMemory;

const RunMockContext = struct {
    permission_mode: PermissionMode,
    permission_decider: ?*const fn (
        *const MockTool,
        MockInput,
        RunMockContext,
    ) PermissionDecisionError!Decision = null,
};

fn failRunDecision(
    _: *const MockTool,
    _: MockInput,
    _: RunMockContext,
) PermissionDecisionError!Decision {
    return injected_permission_error;
}

test "fallible permission gate preserves operational errors" {
    const tool = MockTool{};
    const errors = [_]PermissionDecisionError{
        error.OutOfMemory,
        error.Canceled,
        error.Unexpected,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
    };
    for (errors) |err| {
        injected_permission_error = err;
        try std.testing.expectError(err, decide(
            &tool,
            MockInput{},
            RunMockContext{
                .permission_mode = .ask,
                .permission_decider = failRunDecision,
            },
        ));
    }
}
