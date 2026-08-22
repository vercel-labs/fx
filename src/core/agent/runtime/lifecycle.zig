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
    if (call.argument_integrity == .malformed_json) {
        return makePreparedBlocked(
            result_allocator,
            call,
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
                .cancel_flag = cancel_flag,
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
        preToolUseInputFromCheckpoint(lifecycle.scope, cancel_flag, checkpoint),
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

fn preToolUseInputFromCheckpoint(
    scope: hooks.Scope,
    cancel_flag: ?*std.atomic.Value(bool),
    checkpoint: PreToolUseCheckpoint,
) hooks.PreToolUseInput {
    return .{
        .invocation = .{
            .scope = scope,
            .turn_id = checkpoint.turn_id,
            .cancel_flag = cancel_flag,
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

fn makePreparedBlocked(
    alloc: Allocator,
    call: ToolCall,
    kind: PreparedToolBlockKind,
    reason: ?[]const u8,
) !PreparedToolCall {
    const owned_call = try types.dupeToolCall(alloc, call);
    errdefer types.freeToolCall(alloc, owned_call);
    const model_output = switch (kind) {
        .malformed_arguments => try tool_result_errors.malformedToolArgumentsJson(
            alloc,
            call.name,
        ),
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
