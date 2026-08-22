const std = @import("std");
const builtin = @import("builtin");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permissions = @import("../../permissions/permissions.zig");
const types = @import("../../shared/types.zig");
const pathing = @import("../../workspace/pathing.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const TerminalValidationDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
pub const PermissionActionId = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const max_turn_permission_denials: usize = 64;
const max_consecutive_malformed_argument_batches: usize = 3;

const ApprovedAction = struct {
    authority: command_admission.ToolExecutionAuthority,
    human_approval: command_admission.HumanApprovalProvenance,
    consumed: bool = false,
};

const DeniedAction = struct {
    request_id: PermissionActionId,
    exact_id: PermissionActionId,
    semantic_id: PermissionActionId,
    call: ToolCall,
    approval: ?ApprovedAction = null,
};

pub const TurnPermissionRecovery = struct {
    denied: std.ArrayList(DeniedAction) = .empty,
    next_request_sequence: u64 = 1,

    pub fn deinit(self: *TurnPermissionRecovery, alloc: Allocator) void {
        for (self.denied.items) |entry| types.freeToolCall(alloc, entry.call);
        self.denied.deinit(alloc);
        self.* = .{};
    }

    pub fn rememberAutoDenial(
        self: *TurnPermissionRecovery,
        alloc: Allocator,
        workspace_root: []const u8,
        call: ToolCall,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!?PermissionActionId {
        const reason = outcome.denial_reason orelse
            outcome.decision.denialReason() orelse return null;
        if (reason != .auto_denied) return null;
        const exact_id = permissionActionId(call);
        if (self.indexForExactId(exact_id)) |index| {
            return self.denied.items[index].request_id;
        }
        if (self.denied.items.len == max_turn_permission_denials) return null;
        const next_sequence = std.math.add(
            u64,
            self.next_request_sequence,
            1,
        ) catch return null;
        const request_id = permissionRequestId(self.next_request_sequence);
        const owned_call = try types.dupeToolCall(alloc, call);
        errdefer types.freeToolCall(alloc, owned_call);
        try self.denied.append(alloc, .{
            .request_id = request_id,
            .exact_id = exact_id,
            .semantic_id = try permissionSemanticActionId(
                alloc,
                workspace_root,
                call,
            ),
            .call = owned_call,
        });
        self.next_request_sequence = next_sequence;
        return request_id;
    }

    pub fn deniedCall(
        self: *const TurnPermissionRecovery,
        id: PermissionActionId,
    ) ?ToolCall {
        const index = self.indexForRequestId(id) orelse return null;
        return self.denied.items[index].call;
    }

    pub fn preservedOutcome(
        self: *const TurnPermissionRecovery,
        alloc: Allocator,
        workspace_root: []const u8,
        call: ToolCall,
    ) Allocator.Error!?command_admission.PermissionOutcome {
        const semantic_id = try permissionSemanticActionId(
            alloc,
            workspace_root,
            call,
        );
        for (self.denied.items) |entry| {
            if (std.mem.eql(u8, &entry.semantic_id, &semantic_id)) {
                return .{
                    .decision = .deny,
                    .denial_reason = .auto_denied,
                };
            }
        }
        return null;
    }

    pub fn rememberApproval(
        self: *TurnPermissionRecovery,
        id: PermissionActionId,
        authority: command_admission.ToolExecutionAuthority,
        human_approval: command_admission.HumanApprovalProvenance,
    ) bool {
        if (human_approval == .none) return false;
        const index = self.indexForRequestId(id) orelse return false;
        self.denied.items[index].approval = .{
            .authority = authority,
            .human_approval = human_approval,
        };
        return true;
    }

    pub fn takeApproval(
        self: *TurnPermissionRecovery,
        call: ToolCall,
    ) ?runtime_tool_contracts.LivePermissionRevalidation {
        const index = self.indexForExactId(permissionActionId(call)) orelse
            return null;
        const approval = if (self.denied.items[index].approval) |*value|
            value
        else
            return null;
        if (approval.consumed) return null;
        approval.consumed = true;
        return .{ .action = .{
            .authority = approval.authority,
            .human_approval = approval.human_approval,
        } };
    }

    fn indexForRequestId(
        self: *const TurnPermissionRecovery,
        id: PermissionActionId,
    ) ?usize {
        for (self.denied.items, 0..) |entry, index| {
            if (std.mem.eql(u8, &entry.request_id, &id)) return index;
        }
        return null;
    }

    fn indexForExactId(
        self: *const TurnPermissionRecovery,
        id: PermissionActionId,
    ) ?usize {
        for (self.denied.items, 0..) |entry, index| {
            if (std.mem.eql(u8, &entry.exact_id, &id)) return index;
        }
        return null;
    }
};

pub fn permissionActionId(call: ToolCall) PermissionActionId {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.permission-action.v1\x00");
    hash.update(call.name);
    hash.update("\x00");
    hash.update(call.arguments_json);
    return hash.finalResult();
}

fn permissionRequestId(sequence: u64) PermissionActionId {
    var buffer: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(
        &buffer,
        "fx.permission-request.v1:{d}",
        .{sequence},
    ) catch unreachable;
    var id: PermissionActionId = undefined;
    std.crypto.hash.sha2.Sha256.hash(rendered, &id, .{});
    return id;
}

fn permissionSemanticActionId(
    alloc: Allocator,
    workspace_root: []const u8,
    call: ToolCall,
) Allocator.Error!PermissionActionId {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        call.arguments_json,
        .{},
    ) catch null;
    defer if (parsed) |*value| value.deinit();
    if (parsed) |value| {
        if (value.value == .object) {
            const object = value.value.object;
            if (object.get("command")) |command_value| {
                if (command_value == .string) {
                    const command = normalizeRecoveryCommand(
                        command_value.string,
                    );
                    const cwd = if (object.get("cwd")) |cwd_value|
                        if (cwd_value == .string and
                            !std.mem.eql(u8, cwd_value.string, "."))
                            cwd_value.string
                        else
                            workspace_root
                    else
                        workspace_root;
                    hash.update("command\x00");
                    hash.update(command);
                    hash.update("\x00cwd\x00");
                    hash.update(cwd);
                    return hash.finalResult();
                }
            }
        }
    }
    return permissionActionId(call);
}

fn normalizeRecoveryCommand(command: []const u8) []const u8 {
    var normalized = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.endsWith(u8, normalized, " 2>&1")) {
        normalized = std.mem.trimEnd(
            u8,
            normalized[0 .. normalized.len - " 2>&1".len],
            " \t",
        );
    }
    for ([_][]const u8{
        "sh -c '",
        "bash -c '",
        "zsh -c '",
        "/bin/sh -c '",
        "/bin/bash -c '",
        "/bin/zsh -c '",
    }) |prefix| {
        if (std.mem.startsWith(u8, normalized, prefix) and
            std.mem.endsWith(u8, normalized, "'") and
            normalized.len > prefix.len)
        {
            return std.mem.trim(
                u8,
                normalized[prefix.len .. normalized.len - 1],
                " \t\r\n",
            );
        }
    }
    return normalized;
}

const TerminalValidationDigestDecision = struct {
    append_current: bool,
    repeated: bool,
};

fn containsTerminalValidationDigest(
    digests: []const TerminalValidationDigest,
    wanted: TerminalValidationDigest,
) bool {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest[0..], wanted[0..])) return true;
    }
    return false;
}

fn terminalValidationDigestDecision(
    previous: []const TerminalValidationDigest,
    current: []const TerminalValidationDigest,
    digest: TerminalValidationDigest,
) TerminalValidationDigestDecision {
    return .{
        .append_current = !containsTerminalValidationDigest(current, digest),
        .repeated = containsTerminalValidationDigest(previous, digest),
    };
}

pub const TerminalValidationRetryState = struct {
    previous: std.ArrayList(TerminalValidationDigest) = .empty,
    current: std.ArrayList(TerminalValidationDigest) = .empty,
    stop_after_batch: bool = false,

    pub fn deinit(self: *TerminalValidationRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *TerminalValidationRetryState) void {
        self.current.clearRetainingCapacity();
        self.stop_after_batch = false;
    }

    pub fn observe(
        self: *TerminalValidationRetryState,
        alloc: Allocator,
        call: ToolCall,
        model_output: []const u8,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "terminal")) return;
        if (try tool_result_errors.inspectTerminalActionFieldCorrection(
            alloc,
            model_output,
        ) == null) return;

        var digest: TerminalValidationDigest = undefined;
        std.crypto.hash.sha2.Sha256.hash(model_output, &digest, .{});
        const decision = terminalValidationDigestDecision(
            self.previous.items,
            self.current.items,
            digest,
        );
        if (decision.append_current) try self.current.append(alloc, digest);
        self.stop_after_batch = self.stop_after_batch or decision.repeated;
    }

    pub fn finishBatch(self: *TerminalValidationRetryState) bool {
        if (self.stop_after_batch) return true;
        const previous = self.previous;
        self.previous = self.current;
        self.current = previous;
        self.current.clearRetainingCapacity();
        return false;
    }
};

pub const MalformedArgumentsRetryState = struct {
    consecutive_malformed_batches: usize = 0,
    current_call_count: usize = 0,
    current_malformed_count: usize = 0,

    pub fn beginBatch(self: *MalformedArgumentsRetryState) void {
        self.current_call_count = 0;
        self.current_malformed_count = 0;
    }

    pub fn observe(self: *MalformedArgumentsRetryState, call: ToolCall) void {
        self.current_call_count += 1;
        if (call.argument_integrity != .malformed_json) return;
        self.current_malformed_count += 1;
    }

    pub fn finishBatch(self: *MalformedArgumentsRetryState) bool {
        const all_malformed = self.current_call_count > 0 and
            self.current_call_count == self.current_malformed_count;
        if (!all_malformed) {
            self.consecutive_malformed_batches = 0;
            return false;
        }
        if (self.consecutive_malformed_batches < max_consecutive_malformed_argument_batches) {
            self.consecutive_malformed_batches += 1;
        }
        return self.consecutive_malformed_batches == max_consecutive_malformed_argument_batches;
    }
};

test "malformed arguments retry state stops consecutive all-malformed batches" {
    const malformed_read: ToolCall = .{
        .id = "read-1",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    };
    const malformed_fetch: ToolCall = .{
        .id = "fetch-1",
        .name = "web_fetch",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    };
    const valid_read: ToolCall = .{
        .id = "read-valid",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    };

    var state: MalformedArgumentsRetryState = .{};
    state.beginBatch();
    state.observe(malformed_read);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    state.observe(malformed_fetch);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    state.observe(malformed_fetch);
    try std.testing.expect(state.finishBatch());

    state.beginBatch();
    state.observe(malformed_fetch);
    state.observe(valid_read);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    state.observe(malformed_read);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    state.observe(malformed_read);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    state.observe(malformed_read);
    try std.testing.expect(state.finishBatch());
}

test "terminal validation retry state retains independent batch corrections" {
    const alloc = std.testing.allocator;
    const correction_s = try tool_result_errors.terminalActionFieldCorrectionJson(alloc, .{
        .action = "start",
        .invalid_fields = &.{"session_id"},
        .missing_fields = &.{},
        .allowed_fields = &.{ "action", "command" },
        .conflicts = &.{},
    });
    defer alloc.free(correction_s);
    const correction_t = try tool_result_errors.terminalActionFieldCorrectionJson(alloc, .{
        .action = "read",
        .invalid_fields = &.{"command"},
        .missing_fields = &.{},
        .allowed_fields = &.{ "action", "session_id", "cursor_segment" },
        .conflicts = &.{},
    });
    defer alloc.free(correction_t);
    const call: ToolCall = .{
        .id = "terminal-call",
        .name = "terminal",
        .arguments_json = "{}",
    };

    var state: TerminalValidationRetryState = .{};
    defer state.deinit(alloc);
    state.beginBatch();
    try state.observe(alloc, call, correction_s);
    try state.observe(alloc, call, correction_t);
    try state.observe(alloc, call, correction_s);
    try std.testing.expectEqual(@as(usize, 2), state.current.items.len);
    try std.testing.expect(!state.finishBatch());

    state.beginBatch();
    try state.observe(alloc, call, correction_t);
    try state.observe(alloc, call, "ordinary valid result");
    try state.observe(alloc, call, correction_s);
    try std.testing.expectEqual(@as(usize, 2), state.current.items.len);
    try std.testing.expect(state.finishBatch());
}

test "turn permission recovery binds approval exactly and deduplicates static wrappers" {
    const alloc = std.testing.allocator;
    var state: TurnPermissionRecovery = .{};
    defer state.deinit(alloc);
    const direct: ToolCall = .{
        .id = "direct",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"git push origin HEAD\"}",
    };
    const wrapped: ToolCall = .{
        .id = "wrapped",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"sh -c 'git push origin HEAD'\"}",
    };
    const changed: ToolCall = .{
        .id = "changed",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"git push origin main\"}",
    };
    const request_id = (try state.rememberAutoDenial(
        alloc,
        "/workspace",
        direct,
        .{ .decision = .deny, .denial_reason = .auto_denied },
    )) orelse return error.TestExpectedPermissionRequest;
    try std.testing.expect(!std.mem.eql(
        u8,
        &request_id,
        &permissionActionId(direct),
    ));
    try std.testing.expect(state.deniedCall(request_id) != null);
    try std.testing.expect((try state.preservedOutcome(
        alloc,
        "/workspace",
        wrapped,
    )) != null);
    try std.testing.expect((try state.preservedOutcome(
        alloc,
        "/workspace",
        changed,
    )) == null);

    try std.testing.expect(state.rememberApproval(
        request_id,
        .ordinary,
        .once,
    ));
    const first = state.takeApproval(direct) orelse
        return error.TestExpectedPermissionApproval;
    try std.testing.expectEqual(
        command_admission.HumanApprovalProvenance.once,
        first.action.human_approval,
    );
    try std.testing.expect(state.takeApproval(direct) == null);
    try std.testing.expect(state.takeApproval(changed) == null);
}

/// Human denials retained only for the current agent turn. Entries use the
/// canonical external file action rather than the provider's tool-call ID.
pub const TurnFileMutationDenials = struct {
    identities: std.ArrayList(
        tooling_tool_admission.FileMutationActionIdentity,
    ) = .empty,

    pub noinline fn deinit(self: *TurnFileMutationDenials, alloc: Allocator) void {
        self.identities.deinit(alloc);
        self.* = .{};
    }

    pub fn rememberHumanDenial(
        self: *TurnFileMutationDenials,
        alloc: Allocator,
        identity: tooling_tool_admission.FileMutationActionIdentity,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!void {
        const reason = outcome.denial_reason orelse
            outcome.decision.denialReason() orelse return;
        if (outcome.decision != .deny or reason != .user_denied) return;
        if (self.preservedOutcome(identity) != null) return;
        try self.identities.append(alloc, identity);
    }

    pub fn preservedOutcome(
        self: TurnFileMutationDenials,
        identity: tooling_tool_admission.FileMutationActionIdentity,
    ) ?command_admission.PermissionOutcome {
        for (self.identities.items) |denied| {
            if (denied.eql(identity)) {
                return .{
                    .decision = .deny,
                    .denial_reason = .user_denied,
                };
            }
        }
        return null;
    }
};

pub fn deferVisibleLifecycleUntilAfterPermission(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch") or
        file_mutation_contract.isToolName(tool_name);
}

pub fn deferCapturedCommandLifecycleForAutoPermissionNotice(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    interactive_presentation: bool,
) !bool {
    return interactive_presentation and
        permission_mode == .auto and
        try tooling_tool_admission.callUsesCommandAuthority(
            registry,
            arena,
            call,
        );
}

test "auto permission lifecycle deferral applies only to terminal exec" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exec = ToolCall{
        .id = "exec",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
    };
    const start = ToolCall{
        .id = "start",
        .name = "terminal",
        .arguments_json = "{\"action\":\"start\"}",
    };
    try std.testing.expect(try deferCapturedCommandLifecycleForAutoPermissionNotice(
        test_builtin_tools.registry,
        arena,
        exec,
        .auto,
        true,
    ));
    try std.testing.expect(!try deferCapturedCommandLifecycleForAutoPermissionNotice(
        test_builtin_tools.registry,
        arena,
        start,
        .auto,
        true,
    ));
}

pub fn requestToolPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    revalidation: ?runtime_tool_contracts.LivePermissionRevalidation,
    advertised_dynamic_tool_names: []const []const u8,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, advertised_dynamic_tool_names, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const outcome = hooks.request_tool_permission(hooks.ctx, arena, call, review_turn, mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

pub fn requestPreparedFileMutationPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    prepared: *tooling_tool_admission.PreparedFileMutationCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    advertised_dynamic_tool_names: []const []const u8,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, advertised_dynamic_tool_names, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const request = hooks.request_prepared_file_mutation_permission orelse {
        return permissionErrorOutcome(
            arena,
            call,
            mode,
            error.PreparedFileMutationPermissionUnavailable,
            target_class,
            ctx,
        );
    };
    const outcome = request(hooks.ctx, arena, call, prepared, review_turn, mode, local_grants, live_authority, advertised_dynamic_tool_names) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

fn tracePermissionRequest(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
) void {
    debug_trace.eventf("permission", "before_permission_wait", ctx, "call_id={s} tool_name={s} permission_mode={s} local_grants={d} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), local_grant_count, target_class });
    debug_trace.eventf("permission", "permission_requested", ctx, "call_id={s} tool_name={s} permission_mode={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), target_class });
}

fn permissionErrorOutcome(
    arena: Allocator,
    call: ToolCall,
    mode: PermissionMode,
    err: anyerror,
    target_class: []const u8,
    ctx: TraceContext,
) anyerror!command_admission.PermissionOutcome {
    if (try tooling_tool_admission.permissionTargetResolutionFailureMessage(arena, call.name, err)) |failure| {
        debug_trace.eventf("permission", "permission_target_resolution_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s} approval_source=tool_layer", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
        return .{ .tool_failure = failure };
    }
    debug_trace.eventf("permission", "permission_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
    return err;
}

fn tracePermissionOutcome(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
    outcome: command_admission.PermissionOutcome,
) void {
    const source = permissionOutcomeSource(outcome, mode, local_grant_count);
    if (outcome.tool_failure) |failure| {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s} model_output_bytes={d}", .{ call.id, call.name, @tagName(mode), source, target_class, failure.len });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), source, target_class });
    } else {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
    }
}

fn classifyPermissionTarget(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8, workspace_root: []const u8) []const u8 {
    if (file_mutation_contract.isToolName(call.name)) return "unknown";
    const target = hooks.permission_target_for_call(hooks.ctx, arena, call, advertised_dynamic_tool_names) catch |err| {
        return if (err == error.PathOutsideWorkspace) "true" else "unknown";
    };
    const path_part = if (std.mem.indexOf(u8, target, "::")) |sep| target[0..sep] else target;
    if (!std.fs.path.isAbsolute(path_part)) return "not_path";
    return if (pathing.pathInside(workspace_root, path_part)) "false" else "true";
}

fn permissionOutcomeSource(
    outcome: command_admission.PermissionOutcome,
    mode: PermissionMode,
    local_grant_count: usize,
) []const u8 {
    if (outcome.tool_failure != null) return "tool_failure";
    if (outcome.decision.isDenied()) return "denied";
    if (outcome.execution_authority) |authority| {
        switch (authority) {
            .ordinary => {},
            .run_command => |command_authority| switch (command_authority) {
                .direct_only => return "direct_only",
                .shell_allowed => |shell| return @tagName(shell.source),
            },
            .file_mutation => return "file_mutation",
            .vision_paths => return "vision_paths",
        }
    }
    if (local_grant_count > 0) return "session_grant_or_rule";
    return switch (mode) {
        .auto => "auto_or_rule",
        .ask => "interactive_or_rule",
        .yolo => "yolo",
    };
}

pub noinline fn permissionDeniedStatusLabel(reason: types.ToolPermissionDenialReason) []const u8 {
    return switch (reason) {
        .user_denied => "Denied",
        .auto_denied => "Denied by auto agent",
        .policy_denied => "Denied",
        .permission_required => "Permission required",
    };
}

fn permissionDecisionName(decision: ToolPermissionDecision) []const u8 {
    return @tagName(decision);
}

pub fn retainSessionGrant(hooks: *const AgentRuntimeDeps, arena: Allocator, local_grants: *std.ArrayList(PermissionGrant), permission: []const u8, pattern: []const u8) !void {
    const grant = PermissionGrant{
        .tool_name = try arena.dupe(u8, permission),
        .target_path = try arena.dupe(u8, pattern),
    };
    try appendLocalGrant(arena, local_grants, grant);
    try propagateGrant(hooks, grant);
}

pub fn repeatedDynamicMcpFailure(
    arena: Allocator,
    current_turn_messages: []const types.ChatMessage,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
) !?ToolExecutionResult {
    if (!containsName(advertised_dynamic_tool_names, call.name)) return null;
    if (!try hasTwoEquivalentDynamicMcpFailures(
        arena,
        current_turn_messages,
        call,
    )) return null;
    return .{
        .status = .failure,
        .model_output = try arena.dupe(
            u8,
            "Repeated MCP tool call blocked: two equivalent attempts failed. Change the top-level argument structure, reselect the tool, ask the user, or stop.",
        ),
    };
}

fn hasTwoEquivalentDynamicMcpFailures(
    arena: Allocator,
    messages: []const types.ChatMessage,
    current_call: ToolCall,
) !bool {
    var matching_failures: usize = 0;
    var batch_end = messages.len;
    while (batch_end > 0) {
        var assistant_index = batch_end;
        var found_assistant = false;
        while (assistant_index > 0) {
            assistant_index -= 1;
            if (messages[assistant_index].role == .assistant) {
                found_assistant = true;
                break;
            }
        }
        if (!found_assistant) return false;

        const calls = messages[assistant_index].tool_calls;
        const results = messages[assistant_index + 1 .. batch_end];
        var completed_calls: usize = 0;
        var matching_in_batch: usize = 0;
        var target_completed = false;
        for (calls) |prior_call| {
            const status = completedResultStatus(results, prior_call) orelse continue;
            completed_calls += 1;
            if (std.mem.eql(u8, prior_call.name, "mcp_select_tool") and
                status == .success)
            {
                return false;
            }
            if (!std.mem.eql(u8, prior_call.name, current_call.name)) continue;
            target_completed = true;
            if (status != .failure or
                !try sameTopLevelArgumentShape(
                    arena,
                    prior_call.arguments_json,
                    current_call.arguments_json,
                ))
            {
                return false;
            }
            matching_in_batch += 1;
        }
        if (target_completed) {
            matching_failures += matching_in_batch;
            if (matching_failures >= 2) return true;
        } else if (completed_calls > 0) {
            return false;
        }
        batch_end = assistant_index;
    }
    return false;
}

fn completedResultStatus(
    messages: []const types.ChatMessage,
    call: ToolCall,
) ?types.PersistedToolStatus {
    var matched: ?types.PersistedToolStatus = null;
    for (messages) |message| {
        if (message.role != .tool) continue;
        const call_id = message.tool_call_id orelse continue;
        if (!std.mem.eql(u8, call_id, call.id)) continue;
        if (matched != null or
            message.tool_name == null or
            !std.mem.eql(u8, message.tool_name.?, call.name) or
            message.tool_result_status == null)
        {
            return null;
        }
        matched = message.tool_result_status.?;
    }
    return matched;
}

fn sameTopLevelArgumentShape(
    alloc: Allocator,
    left_json: []const u8,
    right_json: []const u8,
) Allocator.Error!bool {
    var left = try parseArgumentValue(alloc, left_json);
    defer if (left) |*parsed| parsed.deinit();
    var right = try parseArgumentValue(alloc, right_json);
    defer if (right) |*parsed| parsed.deinit();
    if (left == null or right == null) return left == null and right == null;

    const left_value = left.?.value;
    const right_value = right.?.value;
    if (std.meta.activeTag(left_value) != std.meta.activeTag(right_value)) return false;
    if (left_value != .object) return true;
    if (left_value.object.count() != right_value.object.count()) return false;
    var fields = left_value.object.iterator();
    while (fields.next()) |field| {
        const right_field = right_value.object.get(field.key_ptr.*) orelse return false;
        if (std.meta.activeTag(field.value_ptr.*) != std.meta.activeTag(right_field)) {
            return false;
        }
    }
    return true;
}

fn parseArgumentValue(
    alloc: Allocator,
    bytes: []const u8,
) Allocator.Error!?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "third equivalent dynamic MCP failure is blocked from existing turn history" {
    const first_calls = [_]ToolCall{.{
        .id = "call-1",
        .name = "mcp_plain_getThreads",
        .arguments_json = "{\"customerId\":\"\",\"labels\":[]}",
    }};
    const second_calls = [_]ToolCall{.{
        .id = "call-2",
        .name = "mcp_plain_getThreads",
        .arguments_json = "{\"customerId\":\"placeholder\",\"labels\":[\"fake\"]}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &first_calls },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "mcp_plain_getThreads", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &second_calls },
        .{ .role = .tool, .tool_call_id = "call-2", .tool_name = "mcp_plain_getThreads", .tool_result_status = .failure },
    };
    const advertised = [_][]const u8{"mcp_plain_getThreads"};
    const current = ToolCall{
        .id = "call-3",
        .name = "mcp_plain_getThreads",
        .arguments_json = "{\"labels\":[\"another\"],\"customerId\":\"invented\"}",
    };

    const blocked = (try repeatedDynamicMcpFailure(
        std.testing.allocator,
        &messages,
        current,
        &advertised,
    )) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(blocked.model_output);
    try std.testing.expectEqual(runtime_tool_contracts.ToolExecutionStatus.failure, blocked.status);
    try std.testing.expect(std.mem.find(u8, blocked.model_output, "two equivalent attempts") != null);
}

test "dynamic MCP retry containment resets on success shape tool and reselection" {
    const failures = [_]ToolCall{
        .{ .id = "failure-1", .name = "mcp_plain_getThreads", .arguments_json = "{\"id\":\"one\"}" },
        .{ .id = "failure-2", .name = "mcp_plain_getThreads", .arguments_json = "{\"id\":\"two\"}" },
    };
    const other = [_]ToolCall{.{ .id = "other", .name = "read_file", .arguments_json = "{}" }};
    const reselect = [_]ToolCall{.{ .id = "select", .name = "mcp_select_tool", .arguments_json = "{\"name\":\"mcp_plain_getThreads\"}" }};
    const current = ToolCall{ .id = "current", .name = "mcp_plain_getThreads", .arguments_json = "{\"id\":\"three\"}" };
    const advertised = [_][]const u8{"mcp_plain_getThreads"};

    const success_messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = failures[0..1] },
        .{ .role = .tool, .tool_call_id = "failure-1", .tool_name = current.name, .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = failures[1..2] },
        .{ .role = .tool, .tool_call_id = "failure-2", .tool_name = current.name, .tool_result_status = .success },
    };
    try std.testing.expect((try repeatedDynamicMcpFailure(
        std.testing.allocator,
        &success_messages,
        current,
        &advertised,
    )) == null);

    const other_messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &failures },
        .{ .role = .tool, .tool_call_id = "failure-1", .tool_name = current.name, .tool_result_status = .failure },
        .{ .role = .tool, .tool_call_id = "failure-2", .tool_name = current.name, .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &other },
        .{ .role = .tool, .tool_call_id = "other", .tool_name = "read_file", .tool_result_status = .failure },
    };
    try std.testing.expect((try repeatedDynamicMcpFailure(
        std.testing.allocator,
        &other_messages,
        current,
        &advertised,
    )) == null);

    const reselected_messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &failures },
        .{ .role = .tool, .tool_call_id = "failure-1", .tool_name = current.name, .tool_result_status = .failure },
        .{ .role = .tool, .tool_call_id = "failure-2", .tool_name = current.name, .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &reselect },
        .{ .role = .tool, .tool_call_id = "select", .tool_name = "mcp_select_tool", .tool_result_status = .success },
    };
    try std.testing.expect((try repeatedDynamicMcpFailure(
        std.testing.allocator,
        &reselected_messages,
        current,
        &advertised,
    )) == null);

    const changed_shape = ToolCall{ .id = "changed", .name = current.name, .arguments_json = "{\"id\":3}" };
    try std.testing.expect((try repeatedDynamicMcpFailure(
        std.testing.allocator,
        other_messages[0..3],
        changed_shape,
        &advertised,
    )) == null);
}

test "parallel unrelated results do not reset matching dynamic MCP failures" {
    const first_batch = [_]ToolCall{
        .{ .id = "target-1", .name = "mcp_plain_getThreads", .arguments_json = "not-json" },
        .{ .id = "other-1", .name = "read_file", .arguments_json = "{}" },
    };
    const second_batch = [_]ToolCall{.{
        .id = "target-2",
        .name = "mcp_plain_getThreads",
        .arguments_json = "also-not-json",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &first_batch },
        .{ .role = .tool, .tool_call_id = "other-1", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .tool, .tool_call_id = "target-1", .tool_name = "mcp_plain_getThreads", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &second_batch },
        .{ .role = .tool, .tool_call_id = "target-2", .tool_name = "mcp_plain_getThreads", .tool_result_status = .failure },
    };
    const advertised = [_][]const u8{"mcp_plain_getThreads"};
    const current = ToolCall{
        .id = "target-3",
        .name = "mcp_plain_getThreads",
        .arguments_json = "still-not-json",
    };
    const blocked = (try repeatedDynamicMcpFailure(
        std.testing.allocator,
        &messages,
        current,
        &advertised,
    )) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(blocked.model_output);
}

fn appendLocalGrant(arena: Allocator, grants: *std.ArrayList(PermissionGrant), grant: PermissionGrant) !void {
    if (permissions.sessionGrantAllowed(grants.items, grant.tool_name, grant.target_path)) return;
    try grants.append(arena, grant);
}

pub fn applyInitialSessionGrants(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    local_grants: *std.ArrayList(PermissionGrant),
    workspace_root: []const u8,
    call: ToolCall,
    target_path: []const u8,
) !void {
    const command_call = try tooling_tool_admission.callUsesCommandAuthority(
        hooks.tool_registry,
        arena,
        call,
    );
    const permission_name = if (command_call) "run_command" else call.name;
    const target_kind = if (command_call)
        tool_dispatch.PermissionTargetKind.command_cwd
    else if (hooks.tool_registry.lookup(call.name)) |tool|
        tool.permission_target_kind
    else
        .none;
    const grants = try permissions.suggestedSessionGrants(
        arena,
        workspace_root,
        permission_name,
        target_path,
        target_kind,
    );
    for (grants) |grant| {
        try appendLocalGrant(arena, local_grants, grant);
        try propagateGrant(hooks, grant);
    }
}

pub fn applyFrozenFileMutationSessionGrants(
    arena: Allocator,
    hooks: *const AgentRuntimeDeps,
    local_grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        const existed = permissions.sessionGrantAllowed(
            local_grants.items,
            grant.tool_name,
            grant.target_path,
        );
        try appendLocalGrant(arena, local_grants, grant);
        if (!existed) try propagateGrant(hooks, grant);
    }
}

pub fn appendFrozenFileMutationGrants(
    arena: Allocator,
    grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        try appendLocalGrant(arena, grants, grant);
    }
}

fn propagateGrant(hooks: *const AgentRuntimeDeps, grant: PermissionGrant) !void {
    try hooks.propagate_grant(hooks.ctx, grant.tool_name, grant.target_path);
    try hooks.push_event(hooks.ctx, .{ .session_grant = .{
        .tool_name = try std.heap.c_allocator.dupe(u8, grant.tool_name),
        .target_path = try std.heap.c_allocator.dupe(u8, grant.target_path),
    } });
}

pub fn registeredToolValidationFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    if (call.provider_result != null) return null;
    const validate = hooks.validate_tool_call orelse return null;
    return switch (try validate(hooks.ctx, arena, call)) {
        .not_registered, .valid => null,
        .failure => |reason| .{ .model_output = reason, .status = .failure },
    };
}

pub fn toolAvailabilityFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    if (call.provider_result != null) return null;
    const check = hooks.check_tool_availability orelse return null;
    const reason = try check(hooks.ctx, arena, call) orelse return null;
    return .{ .model_output = reason, .status = .failure };
}

pub noinline fn recordRejectedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_rejected orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}

test "turn file mutation denial follows canonical action rather than call identity" {
    const Identity = tooling_tool_admission.FileMutationActionIdentity;
    const action_a: Identity = .{
        .kind = .write,
        .target_hash = @splat(1),
        .first_argument_hash = @splat(2),
        .second_argument_hash = @splat(3),
    };
    var action_b = action_a;
    action_b.first_argument_hash = @splat(4);

    var denials: TurnFileMutationDenials = .{};
    defer denials.deinit(std.testing.allocator);
    try denials.rememberHumanDenial(
        std.testing.allocator,
        action_a,
        .{ .decision = .deny },
    );

    const preserved = denials.preservedOutcome(action_a) orelse
        return error.TestExpectedPreservedDenial;
    try std.testing.expectEqual(ToolPermissionDecision.deny, preserved.decision);
    try std.testing.expectEqual(
        types.ToolPermissionDenialReason.user_denied,
        preserved.denial_reason.?,
    );
    try std.testing.expect(preserved.execution_authority == null);
    try std.testing.expect(preserved.feedback == null);
    try std.testing.expect(denials.preservedOutcome(action_b) == null);
}

test "preserved external file denial stops equivalent retry before effects or disclosure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = [_]tool_dispatch.Tool{test_builtin_tools.write_file};
    const registry: tool_dispatch.Registry = .{ .tools = &tools };
    const target = try std.fs.path.join(
        arena,
        &.{ external, "denied", "nested", "file.txt" },
    );
    const first_arguments = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"private-value\\n\"}}",
        .{target},
    );

    var first = switch (try tooling_tool_admission.prepareFileMutationCall(
        arena,
        .{
            .id = "first-call-id",
            .name = "write_file",
            .arguments_json = first_arguments,
        },
        .{
            .tool_registry = registry,
            .workspace_root = workspace,
        },
    )) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer first.deinit(arena);
    var retry = switch (try tooling_tool_admission.prepareFileMutationCall(
        arena,
        .{
            .id = "different-call-id",
            .name = "write_file",
            .arguments_json = "{\"content\":\"private-value\\n\",\"path\":\"../external/denied/nested/file.txt\"}",
        },
        .{
            .tool_registry = registry,
            .workspace_root = workspace,
        },
    )) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer retry.deinit(arena);
    var changed = switch (try tooling_tool_admission.prepareFileMutationCall(
        arena,
        .{
            .id = "changed-call-id",
            .name = "write_file",
            .arguments_json = "{\"path\":\"../external/denied/nested/file.txt\",\"content\":\"changed\\n\"}",
        },
        .{
            .tool_registry = registry,
            .workspace_root = workspace,
        },
    )) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer changed.deinit(arena);

    var denials: TurnFileMutationDenials = .{};
    defer denials.deinit(alloc);
    try denials.rememberHumanDenial(
        alloc,
        first.externalActionIdentity() orelse
            return error.TestExpectedExternalAction,
        .{ .decision = .deny, .denial_reason = .user_denied },
    );
    const retry_outcome = denials.preservedOutcome(
        retry.externalActionIdentity() orelse
            return error.TestExpectedExternalAction,
    ) orelse return error.TestExpectedPreservedDenial;
    try std.testing.expect(retry_outcome.execution_authority == null);
    try std.testing.expect(retry_outcome.feedback == null);
    try std.testing.expect(denials.preservedOutcome(
        changed.externalActionIdentity() orelse
            return error.TestExpectedExternalAction,
    ) == null);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(
            std.testing.io,
            try std.fs.path.join(arena, &.{ external, "denied" }),
            .{},
        ),
    );
}

test "turn file mutation denial state is local and does not retain approvals" {
    const Identity = tooling_tool_admission.FileMutationActionIdentity;
    const action_a: Identity = .{
        .kind = .write,
        .target_hash = @splat(1),
        .first_argument_hash = @splat(2),
        .second_argument_hash = @splat(3),
    };
    var action_b = action_a;
    action_b.target_hash = @splat(4);

    var root_denials: TurnFileMutationDenials = .{};
    defer root_denials.deinit(std.testing.allocator);
    var child_denials: TurnFileMutationDenials = .{};
    defer child_denials.deinit(std.testing.allocator);

    try root_denials.rememberHumanDenial(
        std.testing.allocator,
        action_a,
        .{ .decision = .once, .human_approval = .once },
    );
    try root_denials.rememberHumanDenial(
        std.testing.allocator,
        action_a,
        .{ .decision = .always, .human_approval = .always },
    );
    try root_denials.rememberHumanDenial(
        std.testing.allocator,
        action_a,
        .{ .decision = .policy_denied, .denial_reason = .policy_denied },
    );
    try std.testing.expect(root_denials.preservedOutcome(action_a) == null);

    try root_denials.rememberHumanDenial(
        std.testing.allocator,
        action_a,
        .{ .decision = .deny, .denial_reason = .user_denied },
    );
    try child_denials.rememberHumanDenial(
        std.testing.allocator,
        action_b,
        .{ .decision = .deny, .denial_reason = .user_denied },
    );
    try std.testing.expect(root_denials.preservedOutcome(action_a) != null);
    try std.testing.expect(root_denials.preservedOutcome(action_b) == null);
    try std.testing.expect(child_denials.preservedOutcome(action_a) == null);
    try std.testing.expect(child_denials.preservedOutcome(action_b) != null);
}
