const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const types = @import("../../shared/types.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

const PreToolUseDispatchError = Allocator.Error || error{
    Cancelled,
    LifecycleFailedClosed,
};

pub const LifecycleContext = struct {
    view: hooks.RuntimeView,
    scope: hooks.Scope,
    outcome_allocator: Allocator,
};

pub const StopCheckpoint = struct {
    turn_id: u64,
    step_index: usize,
    assistant_text: []const u8,
    provider_disposition: types.ProviderCompletionDisposition,
    can_continue: bool,
};

pub const PostTurnEndCheckpoint = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition,
};

pub const AttentionRequiredCheckpoint = struct {
    turn_id: u64,
    kind: hooks.AttentionKind,
};

const PreToolUseCheckpoint = struct {
    turn_id: u64,
    step_index: usize,
    call: ToolCall,
};

pub const PreparedToolBlockKind = enum {
    malformed_arguments,
    lifecycle_block,
    lifecycle_failed_closed,
    route_unavailable,
    required_vision,
};

pub const PreparedToolCall = union(enum) {
    provider_executed: ToolCall,
    ready: ToolCall,
    blocked: struct {
        call: ToolCall,
        model_output: ?[]u8,
        kind: PreparedToolBlockKind,
    },

    pub fn call(self: PreparedToolCall) ToolCall {
        return switch (self) {
            .provider_executed => |tool_call| tool_call,
            .ready => |tool_call| tool_call,
            .blocked => |blocked| blocked.call,
        };
    }

    pub fn takeBlockedOutput(self: *PreparedToolCall) ?[]u8 {
        return switch (self.*) {
            .blocked => |*blocked| blk: {
                const output = blocked.model_output;
                blocked.model_output = null;
                break :blk output;
            },
            else => null,
        };
    }

    pub fn deinit(self: *PreparedToolCall, alloc: Allocator) void {
        switch (self.*) {
            .provider_executed => |tool_call| types.freeToolCall(alloc, tool_call),
            .ready => |tool_call| types.freeToolCall(alloc, tool_call),
            .blocked => |blocked| {
                types.freeToolCall(alloc, blocked.call);
                if (blocked.model_output) |output| alloc.free(output);
            },
        }
        self.* = undefined;
    }

    pub fn deinitOutput(self: *PreparedToolCall, alloc: Allocator) void {
        switch (self.*) {
            .blocked => |*blocked| {
                if (blocked.model_output) |output| alloc.free(output);
                blocked.model_output = null;
            },
            else => {},
        }
    }
};

test "PreparedToolCall exposes only consuming blocked output access" {
    try std.testing.expect(!@hasDecl(PreparedToolCall, "blockedOutput"));
}

test "non-object function arguments are blocked before hooks with safe replay input" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,
        fn run(raw: *anyopaque, _: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .continue_;
        }
    };
    var capture = Capture{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "observe", .ctx = &capture, .run = Capture.run });
    const context = LifecycleContext{
        .view = runtime.freeze(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    for ([_][]const u8{ "[]", "[1]", "42", "null", "true", "\"text\"" }) |arguments| {
        const call = ToolCall{ .id = "rejected", .name = "read_file", .arguments_json = arguments };
        var prepared = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, call);
        defer prepared.deinit(alloc);
        try std.testing.expect(prepared == .blocked);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
        try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
        try std.testing.expectEqualStrings("rejected", prepared.call().id);
        try std.testing.expectEqualStrings("read_file", prepared.call().name);
        try std.testing.expect(prepared.call().argument_integrity != .valid);
        try std.testing.expect(std.mem.find(u8, prepared.blocked.model_output.?, "object") != null);
        try std.testing.expectEqualStrings(arguments, call.arguments_json);
    }

    const arguments = " {\"items\":[1,{\"nested\":true}]} ";
    var valid = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "valid",
        .name = "read_file",
        .arguments_json = arguments,
    });
    defer valid.deinit(alloc);
    try std.testing.expect(valid == .ready);
    try std.testing.expectEqualStrings(arguments, valid.call().arguments_json);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "non-object calls blocked by policy retain the policy result and safe replay input" {
    const alloc = std.testing.allocator;
    const call = ToolCall{ .id = "held", .name = "read_file", .arguments_json = "[]" };
    var prepared = try makePreparedBlocked(alloc, call, .lifecycle_block, "policy held this call");
    defer prepared.deinit(alloc);
    try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
    try std.testing.expect(prepared.call().argument_integrity != .valid);
    try std.testing.expect(std.mem.find(u8, prepared.blocked.model_output.?, "policy held this call") != null);
    try std.testing.expectEqualStrings("[]", call.arguments_json);
}

test "non-object provider-executed input remains provider owned" {
    const alloc = std.testing.allocator;
    const context = LifecycleContext{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    };
    var prepared = try prepareToolCallForLifecycle(alloc, context, null, 1, 0, .{
        .id = "native",
        .name = "native_tool",
        .arguments_json = "[]",
        .provenance = .provider_executed,
        .provider_result = "recorded result",
    });
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared == .provider_executed);
    try std.testing.expectEqualStrings("[]", prepared.call().arguments_json);
    try std.testing.expectEqualStrings("recorded result", prepared.call().provider_result.?);
}

fn checkNonObjectPreparationAllocationFailures(alloc: Allocator) !void {
    var prepared = try prepareToolCallForLifecycle(alloc, .{
        .view = hooks.RuntimeView.empty(),
        .scope = .{ .kind = .ask, .workspace_root = "/fixture" },
        .outcome_allocator = alloc,
    }, null, 1, 0, .{ .id = "call", .name = "read_file", .arguments_json = "[1]" });
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared == .blocked);
    try std.testing.expectEqualStrings("{}", prepared.call().arguments_json);
}

test "non-object preparation cleans every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkNonObjectPreparationAllocationFailures, .{});
}

pub noinline fn prepareToolCallForLifecycle(
    result_allocator: Allocator,
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    turn_id: u64,
    step_index: usize,
    call: ToolCall,
) !PreparedToolCall {
    return prepareToolCallFromCheckpoint(
        result_allocator,
        lifecycle,
        cancel_flag,
        .{
            .turn_id = turn_id,
            .step_index = step_index,
            .call = call,
        },
    );
}

fn prepareToolCallFromCheckpoint(
    result_allocator: Allocator,
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) !PreparedToolCall {
    const call = checkpoint.call;
    if (call.provenance == .provider_executed) {
        return .{ .provider_executed = try types.dupeToolCall(result_allocator, call) };
    }
    const integrity = if (call.argument_integrity == .valid)
        try types.ToolArgumentIntegrity.classifyFunctionInput(result_allocator, call.arguments_json)
    else
        call.argument_integrity;
    if (integrity != .valid) {
        var rejected = call;
        rejected.argument_integrity = integrity;
        return makePreparedBlocked(
            result_allocator,
            rejected,
            .malformed_arguments,
            null,
        );
    }

    var outcome = dispatchPreToolUseCheckpoint(
        lifecycle,
        cancel_flag,
        checkpoint,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.LifecycleFailedClosed => makePreparedBlocked(
                result_allocator,
                call,
                .lifecycle_failed_closed,
                null,
            ),
        };
    };
    defer outcome.deinit(lifecycle.outcome_allocator);
    if (cancelRequested(cancel_flag)) return error.Cancelled;

    return preparedCallFromPreToolUseOutcome(result_allocator, call, outcome);
}

pub fn dispatchStopCheckpoint(
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: StopCheckpoint,
) error{Cancelled}!hooks.StopOutcome {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    var outcome = lifecycle.view.runStop(
        lifecycle.outcome_allocator,
        .{
            .invocation = .{
                .scope = lifecycle.scope,
                .turn_id = checkpoint.turn_id,
            },
            .step_index = checkpoint.step_index,
            .assistant_text = checkpoint.assistant_text,
            .provider_disposition = checkpoint.provider_disposition,
            .can_continue = checkpoint.can_continue,
        },
    );
    errdefer outcome.deinit(lifecycle.outcome_allocator);
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    return outcome;
}

pub fn dispatchPostTurnEndCheckpoint(
    lifecycle: LifecycleContext,
    checkpoint: PostTurnEndCheckpoint,
) void {
    lifecycle.view.runPostTurnEnd(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .outcome = checkpoint.outcome,
        .provider_disposition = checkpoint.provider_disposition,
    });
}

pub fn dispatchAttentionRequiredCheckpoint(
    lifecycle: LifecycleContext,
    checkpoint: AttentionRequiredCheckpoint,
) void {
    lifecycle.view.runAttentionRequired(.{
        .invocation = .{
            .scope = lifecycle.scope,
            .turn_id = checkpoint.turn_id,
        },
        .kind = checkpoint.kind,
    });
}

fn dispatchPreToolUseCheckpoint(
    lifecycle: LifecycleContext,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) PreToolUseDispatchError!hooks.PreToolUseOutcome {
    if (cancelRequested(cancel_flag)) return error.Cancelled;
    return lifecycle.view.runPreToolUse(
        lifecycle.outcome_allocator,
        preToolUseInputFromCheckpoint(lifecycle.scope, checkpoint),
    ) catch |err| {
        if (cancelRequested(cancel_flag)) return error.Cancelled;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HandlerFailed,
            error.Cancelled,
            error.InvalidHandlerOutput,
            error.HandlerOutputTooLarge,
            => error.LifecycleFailedClosed,
        };
    };
}

fn preToolUseInputFromCheckpoint(scope: hooks.Scope, checkpoint: PreToolUseCheckpoint) hooks.PreToolUseInput {
    return .{
        .invocation = .{
            .scope = scope,
            .turn_id = checkpoint.turn_id,
        },
        .step_index = checkpoint.step_index,
        .call_id = checkpoint.call.id,
        .tool_name = checkpoint.call.name,
        .arguments_json = checkpoint.call.arguments_json,
    };
}

fn preparedCallFromPreToolUseOutcome(
    alloc: Allocator,
    call: ToolCall,
    outcome: hooks.PreToolUseOutcome,
) !PreparedToolCall {
    return switch (outcome) {
        .unchanged => .{ .ready = try types.dupeToolCall(alloc, call) },
        .rewritten => |arguments_json| .{
            .ready = try dupeToolCallWithArguments(
                alloc,
                call,
                arguments_json,
            ),
        },
        .blocked => |reason| try makePreparedBlocked(
            alloc,
            call,
            .lifecycle_block,
            reason,
        ),
    };
}

/// Returns an owned copy for an already-blocked call, never for execution.
pub fn dupeBlockedToolCall(alloc: Allocator, call: ToolCall) !ToolCall {
    var replay = call;
    if (call.provenance != .provider_executed) {
        replay.argument_integrity = if (call.argument_integrity == .valid)
            try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, call.arguments_json)
        else
            call.argument_integrity;
        if (replay.argument_integrity != .valid) replay.arguments_json = "{}";
    }
    return types.dupeToolCall(alloc, replay);
}

fn makePreparedBlocked(
    alloc: Allocator,
    call: ToolCall,
    kind: PreparedToolBlockKind,
    reason: ?[]const u8,
) !PreparedToolCall {
    const owned_call = try dupeBlockedToolCall(alloc, call);
    errdefer types.freeToolCall(alloc, owned_call);
    const model_output = switch (kind) {
        .malformed_arguments => if (call.argument_integrity == .non_object_json)
            try tool_result_errors.nonObjectToolArgumentsJson(alloc, call.name)
        else
            try tool_result_errors.malformedToolArgumentsJson(alloc, call.name),
        .lifecycle_block => try tool_result_errors.preToolUseBlockedJson(
            alloc,
            call.name,
            reason.?,
        ),
        .lifecycle_failed_closed => try tool_result_errors.preToolUseFailedClosedJson(
            alloc,
            call.name,
        ),
        .route_unavailable, .required_vision => unreachable,
    };
    return .{ .blocked = .{
        .call = owned_call,
        .model_output = model_output,
        .kind = kind,
    } };
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

fn dupeToolCallWithArguments(
    alloc: Allocator,
    call: ToolCall,
    arguments_json: []const u8,
) !ToolCall {
    var copy = try types.dupeToolCall(alloc, call);
    errdefer types.freeToolCall(alloc, copy);
    const rewritten = try alloc.dupe(u8, arguments_json);
    alloc.free(copy.arguments_json);
    copy.arguments_json = rewritten;
    copy.argument_integrity = .valid;
    return copy;
}
