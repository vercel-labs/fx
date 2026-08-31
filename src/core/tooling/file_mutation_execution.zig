const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const max_file_mutation_success_bytes: usize = 8 * 1024;

const FileMutationPrepareError = @typeInfo(
    @typeInfo(@TypeOf(file_mutation.prepare)).@"fn".return_type.?,
).error_union.error_set;

const FileMutationApplyError = @typeInfo(
    @typeInfo(@TypeOf(file_mutation.apply)).@"fn".return_type.?,
).error_union.error_set;

pub const Input = struct {
    call_allocator: Allocator,
    result_allocator: Allocator,
    call: ToolCall,
    authorization: ?file_mutation_contract.FileExecutionAuthorization,
    maybe_cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_id: ?types.ToolLifecycleId = null,
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

pub fn execute(input: Input) Error!ToolExecutionResult {
    var authorization = input.authorization orelse return fileMutationFailure(
        input.result_allocator,
        "file mutation execution authority is invalid",
        "preflight failed",
    );
    if (allocatorsEqual(input.call_allocator, input.result_allocator)) {
        return fileMutationFailure(
            input.result_allocator,
            "file mutation execution requires distinct call and result owners",
            "preflight failed",
        );
    }
    if (authorization.prepared == null) {
        if (authorization.policy_targets.prompt_required) {
            return fileMutationFailure(
                input.result_allocator,
                "file mutation execution requires prepared approval",
                "preflight failed",
            );
        }
        authorization.prepared = switch (file_mutation.prepare(
            input.call_allocator,
            input.call,
            authorization.input,
            authorization.policy_targets,
        ) catch |err| return mapFileMutationOperationalError(err)) {
            .prepared => |prepared| prepared,
            .semantic_failure => |reason| return fileMutationFailure(
                input.result_allocator,
                reason,
                "preflight failed",
            ),
        };
    }

    const prepared = authorization.prepared.?;
    if (file_mutation_contract.preparedMutationIsNoop(prepared)) {
        return .{
            .status = .success,
            .model_output = try std.fmt.allocPrint(
                input.result_allocator,
                "No changes to {s}; it already contains the requested content",
                .{prepared.display_path},
            ),
        };
    }

    const prepared_result = try prepareFileMutationSuccessResult(
        input.call_allocator,
        input.result_allocator,
        prepared,
    );
    var prepared_result_owned = true;
    defer if (prepared_result_owned) {
        input.result_allocator.free(prepared_result.model_output);
    };

    var fallback_cancel_flag = std.atomic.Value(bool).init(false);
    const applied = file_mutation.apply(
        input.call_allocator,
        input.result_allocator,
        input.call,
        authorization,
        input.maybe_cancel_flag orelse &fallback_cancel_flag,
    ) catch |err| return mapFileMutationApplyError(
        input.result_allocator,
        err,
    );
    return switch (applied) {
        .committed => |committed_file_handoff| blk: {
            var handoff = committed_file_handoff;
            if (input.lifecycle_id) |lifecycle_id| {
                captureFullViewAfterCommit(
                    &handoff,
                    input.result_allocator,
                    prepared.after_content,
                    lifecycle_id,
                );
            }
            prepared_result_owned = false;
            break :blk .{
                .status = .success,
                .model_output = prepared_result.model_output,
                .tool_result_memory = prepared_result.memory,
                .tool_result_memory_prepared = true,
                .committed_file_handoff = handoff,
            };
        },
        .rejected => |rejection| fileMutationRejectionResult(
            input.result_allocator,
            authorization.policy_targets,
            input.call,
            rejection,
        ),
    };
}

fn captureFullViewAfterCommit(
    handoff: *file_mutation.CommittedFileHandoff,
    alloc: Allocator,
    after_content: []const u8,
    lifecycle_id: types.ToolLifecycleId,
) void {
    handoff.attachFullView(alloc, after_content, lifecycle_id) catch |err| {
        debug_trace.logf(
            "tool",
            "committed file full-view capture unavailable call_id={s} err={s}",
            .{ lifecycle_id.call_id, @errorName(err) },
        );
    };
}

fn prepareFileMutationSuccessResult(
    call_alloc: Allocator,
    result_alloc: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) Allocator.Error!tool_result_limits.PreparedInlineResult {
    var encoded_path = try text_utils.encodeTerminalSafe(
        call_alloc,
        fileMutationDisplayTargetPath(prepared.policy_targets),
        diff_mod.max_encoded_path_bytes,
    );
    defer encoded_path.deinit(call_alloc);

    const raw_output = try std.fmt.allocPrint(
        call_alloc,
        "{s} {s} ({d} bytes)",
        .{
            if (prepared.kind == .write) "wrote" else "edited",
            encoded_path.bytes,
            prepared.after_content.len,
        },
    );
    defer call_alloc.free(raw_output);
    return tool_result_limits.prepareInlineResult(
        result_alloc,
        prepared.tool_name,
        raw_output,
        max_file_mutation_success_bytes,
    );
}

fn fileMutationDisplayTargetPath(
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) []const u8 {
    if (policy_targets.anchor.scope == .external) {
        return policy_targets.canonical_target_path;
    }
    const start = @min(
        policy_targets.anchor.path_end + 1,
        policy_targets.canonical_target_path.len,
    );
    return policy_targets.canonical_target_path[start..];
}

fn fileMutationFailure(
    alloc: Allocator,
    message: []const u8,
    detail: []const u8,
) Allocator.Error!ToolExecutionResult {
    return .{
        .status = .failure,
        .status_detail = detail,
        .model_output = try alloc.dupe(u8, message),
    };
}

fn allocatorsEqual(a: Allocator, b: Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

fn mapFileMutationOperationalError(
    err: FileMutationPrepareError,
) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn mapFileMutationApplyError(
    alloc: Allocator,
    err: FileMutationApplyError,
) Error!ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultContractViolation => fileMutationFailure(
            alloc,
            "file mutation result contract is invalid",
            "preflight failed",
        ),
    };
}

fn fileMutationRejectionResult(
    alloc: Allocator,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
    call: ToolCall,
    rejection: file_mutation.ApplyRejection,
) Allocator.Error!ToolExecutionResult {
    debug_trace.logf(
        "tool",
        "typed file mutation apply rejected call_id={s} reason={s} residue_count={d}",
        .{ call.id, @tagName(rejection.reason), rejection.created_parent_residue.len },
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(switch (rejection.reason) {
        .binding_mismatch => "file mutation rejected because the approved call no longer matches",
        .stale_preimage => "file mutation rejected because the file changed after preview; make a new tool call for a fresh preview",
        .cancelled => "file mutation cancelled before commit",
        .traversal_changed => "file mutation rejected because the approved path traversal changed",
        .staged_source_changed => "file mutation rejected because the staged file changed before commit",
        .io_failure => "file mutation failed before commit",
    }) catch return error.OutOfMemory;
    if (rejection.created_parent_residue.len > 0) {
        out.writer.writeAll("; approved parent cleanup residue:") catch
            return error.OutOfMemory;
        for (rejection.created_parent_residue) |residue| {
            const raw_path =
                policy_targets.canonical_target_path[0..residue.path_end];
            var encoded = try text_utils.encodeTerminalSafe(
                alloc,
                raw_path,
                diff_mod.max_encoded_label_bytes,
            );
            defer encoded.deinit(alloc);
            out.writer.print(" {s} ({s})", .{
                encoded.bytes,
                @tagName(residue.reason),
            }) catch return error.OutOfMemory;
        }
    }
    return .{
        .status = .failure,
        .status_detail = switch (rejection.reason) {
            .stale_preimage => "stale preview",
            .cancelled => "cancelled",
            else => "rejected",
        },
        .model_output = try out.toOwnedSlice(),
    };
}

test "canonical file executor rejects aliased call and result owners before mutation" {
    const io_mod = @import("../shared/io.zig");
    const permissions = @import("../permissions/permissions.zig");

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "aliased-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"aliased.txt\",\"content\":\"blocked\\n\"}",
    };
    const mutation_input: file_mutation_contract.FileMutationInput = .{ .write = .{
        .path = try arena.dupe(u8, "aliased.txt"),
        .content = try arena.dupe(u8, "blocked\n"),
    } };
    const policy_targets = switch (try permissions.evaluateFileMutationTargets(
        arena,
        workspace,
        mutation_input,
        .auto,
        .{},
        &.{},
        &.{},
    )) {
        .evaluated => |value| value,
        .target_resolution_failure, .policy_denied => return error.TestExpectedAllowed,
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    const result = try execute(.{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authorization = .{
            .input = mutation_input,
            .policy_targets = policy_targets,
        },
        .maybe_cancel_flag = &cancel_flag,
    });

    try std.testing.expectEqual(
        tool_contracts.ToolExecutionStatus.failure,
        result.status,
    );
    try std.testing.expectEqualStrings(
        "file mutation execution requires distinct call and result owners",
        result.model_output,
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "workspace/aliased.txt", .{}),
    );
}

test "file executor retains full review input after committing an interactive write" {
    const io_mod = @import("../shared/io.zig");
    const permissions = @import("../permissions/permissions.zig");

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var call_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const call: ToolCall = .{
        .id = "full-review",
        .name = "write_file",
        .arguments_json = "{\"path\":\"full.txt\",\"content\":\"full review\\n\"}",
    };
    const mutation_input: file_mutation_contract.FileMutationInput = .{ .write = .{
        .path = try call_alloc.dupe(u8, "full.txt"),
        .content = try call_alloc.dupe(u8, "full review\n"),
    } };
    var allow_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("**"),
        .action = .allow,
    }};
    const policy_targets = switch (try permissions.evaluateFileMutationTargets(
        call_alloc,
        workspace,
        mutation_input,
        .auto,
        .{ .rules = &allow_rules },
        &.{},
        &.{},
    )) {
        .evaluated => |value| value,
        .target_resolution_failure, .policy_denied => return error.TestExpectedAllowed,
    };

    const result = try execute(.{
        .call_allocator = call_alloc,
        .result_allocator = result_alloc,
        .call = call,
        .authorization = .{
            .input = mutation_input,
            .policy_targets = policy_targets,
        },
        .lifecycle_id = .{ .turn_id = 37, .call_id = "full-review" },
    });
    const handoff = result.committed_file_handoff orelse return error.TestExpectedCommit;
    const full_view = handoff.full_view orelse return error.TestExpectedFullView;

    try std.testing.expectEqualStrings("full review\n", full_view.after_content);
    try std.testing.expectEqual(@as(u64, 37), full_view.lifecycle_id.turn_id);
    try std.testing.expectEqualStrings("full-review", full_view.lifecycle_id.call_id);

    var installed_file = try tmp.dir.openFile(io_mod.getIo(), "workspace/full.txt", .{});
    defer installed_file.close(io_mod.getIo());
    const installed = try io_mod.readFileToEnd(alloc, &installed_file, 1024);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("full review\n", installed);
}

test "post-commit full view capture failure preserves the committed file" {
    const io_mod = @import("../shared/io.zig");
    const permissions = @import("../permissions/permissions.zig");

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var call_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const call: ToolCall = .{
        .id = "full-review-fallback",
        .name = "write_file",
        .arguments_json = "{\"path\":\"fallback.txt\",\"content\":\"committed\\n\"}",
    };
    const mutation_input: file_mutation_contract.FileMutationInput = .{ .write = .{
        .path = try call_alloc.dupe(u8, "fallback.txt"),
        .content = try call_alloc.dupe(u8, "committed\n"),
    } };
    const policy_targets = switch (try permissions.evaluateFileMutationTargets(
        call_alloc,
        workspace,
        mutation_input,
        .auto,
        .{},
        &.{},
        &.{},
    )) {
        .evaluated => |value| value,
        .target_resolution_failure, .policy_denied => return error.TestExpectedAllowed,
    };
    const prepared = switch (try file_mutation.prepare(
        call_alloc,
        call,
        mutation_input,
        policy_targets,
    )) {
        .prepared => |value| value,
        .semantic_failure => return error.TestExpectedPreparedMutation,
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var handoff = switch (try file_mutation.apply(
        call_alloc,
        result_alloc,
        call,
        .{
            .input = mutation_input,
            .policy_targets = policy_targets,
            .prepared = prepared,
        },
        &cancel_flag,
    )) {
        .committed => |value| value,
        .rejected => return error.TestExpectedCommit,
    };
    defer handoff.deinit(result_alloc);

    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        captureFullViewAfterCommit(
            &handoff,
            failing.allocator(),
            prepared.after_content,
            .{ .turn_id = 38, .call_id = "full-review-fallback" },
        );
        try std.testing.expect(handoff.full_view == null);
    }

    var installed_file = try tmp.dir.openFile(io_mod.getIo(), "workspace/fallback.txt", .{});
    defer installed_file.close(io_mod.getIo());
    const installed = try io_mod.readFileToEnd(alloc, &installed_file, 1024);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("committed\n", installed);
}
