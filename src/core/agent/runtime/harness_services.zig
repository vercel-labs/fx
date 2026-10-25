//! The running turn's services for `proto_fx` (`src/core/harness`). A
//! harness tool call takes the same steps as a model's call in this turn:
//! the node's offered tools, validation and availability, live authority,
//! the permission request with its prompt or automatic review (marked as
//! harness origin), the execution authority that request grants, and
//! committing the result. Only the transcript rows differ: the result goes
//! back to Python, and the command that ran Python is the recorded call.
const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const harness_services = @import("../../harness/services.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const auto_classifier_context = @import("../../permissions/auto_classifier_context.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const skill_contract = @import("../../skills/skill_contract.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_deps = @import("deps.zig");
const runtime_config = @import("config.zig");
const runtime_tool_admission = @import("tool_admission.zig");
const runtime_text_completion = @import("text_completion.zig");
const orchestrator = @import("orchestrator.zig");

const Allocator = std.mem.Allocator;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const PermissionGrant = types.PermissionGrant;

/// Captured where the turn runs a tool call; it must outlive that call.
pub const Turn = struct {
    deps: *const AgentRuntimeDeps,
    config: *const runtime_config.Config,
    mode: types.PermissionMode,
    grants: []const PermissionGrant,
    root_user_intent_context: []const u8,
    current_turn_messages: []const types.ChatMessage,
    advertised_dynamic_tool_names: []const []const u8,
    advertised_dynamic_tools: []const agent_stream_provider.DynamicFunctionTool,
    skill_locations: ?*const skill_contract.Locations = null,
    credential: types.CredentialLease,
    model: []const u8,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    session_id: ?[]const u8 = null,
    trace: debug_trace.TraceContext = .{},
    /// One harness permission request at a time, and the grants they add.
    lock: std.Io.Mutex = .init,
    grants_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    added_grants: std.ArrayList(PermissionGrant) = .empty,

    pub fn deinit(self: *Turn) void {
        self.grants_arena.deinit();
    }

    pub fn services(self: *Turn) harness_services.Services {
        return .{ .context = self, .call_tool_fn = callTool, .tool_names_fn = toolNames, .complete_fn = complete };
    }

    /// Whether the model of this turn is offered `name`.
    fn offers(self: *const Turn, name: []const u8) bool {
        for (self.advertised_dynamic_tool_names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        if (self.config.advertised_tool_names.len == 0) return self.deps.tool_registry.lookup(name) != null;
        for (self.config.advertised_tool_names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }
};

fn refused(arena: Allocator, comptime fmt: []const u8, args: anytype) !harness_services.ToolOutcome {
    return .{ .status = .refused, .output = try arena.print(fmt, args) };
}

fn toolNames(context: *anyopaque, arena: Allocator) anyerror![]const []const u8 {
    const self: *Turn = @ptrCast(@alignCast(context));
    var names: std.ArrayList([]const u8) = .empty;
    if (self.config.advertised_tool_names.len > 0) {
        try names.appendSlice(arena, self.config.advertised_tool_names);
    } else for (self.deps.tool_registry.tools) |tool| try names.append(arena, tool.name);
    try names.appendSlice(arena, self.advertised_dynamic_tool_names);
    return names.items;
}

fn callTool(context: *anyopaque, arena: Allocator, request: harness_services.ToolRequest) anyerror!harness_services.ToolOutcome {
    const self: *Turn = @ptrCast(@alignCast(context));
    const deps = self.deps;
    const call: types.ToolCall = .{ .id = request.call_id, .name = request.name, .arguments_json = request.arguments_json };
    if (!self.offers(call.name)) return refused(arena, "this agent has no tool named {s}", .{call.name});
    if (try runtime_tool_admission.registeredToolValidationFailure(deps, arena, call)) |failure| return .{ .status = .refused, .output = failure.model_output };
    if (try runtime_tool_admission.toolAvailabilityFailure(deps, arena, call)) |failure| return .{ .status = .refused, .output = failure.model_output };
    debug_trace.eventf("harness", "tool_requested", self.trace, "call_id={s} tool_name={s}", .{ call.id, call.name });

    const admitted = (try admit(self, arena, call, request.caller)) orelse return .{ .status = .cancelled, .output = "" };
    const permit = switch (admitted) {
        .outcome => |outcome| return outcome,
        .permit => |permit| permit,
    };

    // A file mutation keeps what it prepared apart from its result, as the
    // agent loop's own calls do.
    var call_arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer call_arena_state.deinit();
    const is_file_mutation = permit.authority == .file_mutation;
    const call_allocator = if (is_file_mutation) call_arena_state.allocator() else arena;
    var execution = deps.executeToolCall(.{
        .skill_locations = self.skill_locations,
        .call_allocator = call_allocator,
        .result_allocator = arena,
        .call = if (is_file_mutation) try types.dupeToolCall(call_allocator, call) else call,
        .authority = permit.authority,
        .credential = self.credential,
        .permission_mode = permit.mode,
        .root_user_intent_context = self.root_user_intent_context,
        .root_user_evidence_complete = true,
        .current_turn_messages = self.current_turn_messages,
        .session_grants = permit.grants,
        .live_authority = permit.live,
        .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,
        .max_tool_result_bytes = self.config.max_tool_result_bytes,
        .harness = self.services(),
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.Cancelled) return .{ .status = .cancelled, .output = "" };
        return .{ .status = .failure, .output = try deps.format_tool_execution_error(deps.ctx, arena, call.name, err) };
    };
    if (execution.result_commit) |commit| {
        commit.commit() catch |err| {
            commit.cancel();
            return .{ .status = .failure, .output = try arena.print("{s} ran but its result could not be committed: {s}", .{ call.name, @errorName(err) }) };
        };
        execution.result_commit = null;
    }
    if (execution.committed_file_handoff) |handoff| {
        // The diff and the undo record, as for the model's own edits.
        _ = deps.publish_committed_file_handoff(deps.ctx, handoff);
    } else if (execution.diff_entry) |payload| {
        deps.push_diff_block(deps.ctx, payload) catch {};
    }
    debug_trace.eventf("harness", "tool_finished", self.trace, "call_id={s} tool_name={s} status={s}", .{ call.id, call.name, @tagName(execution.status) });
    if (execution.cancelled) return .{ .status = .cancelled, .output = "" };
    return .{
        .status = if (execution.status == .success) .success else .failure,
        .output = try arena.dupe(u8, execution.model_output),
    };
}

const Permit = struct {
    authority: command_admission.ToolExecutionAuthority,
    mode: types.PermissionMode,
    grants: []const PermissionGrant,
    live: ?runtime_deps.LiveToolAuthority,
};

const Admission = union(enum) {
    /// Settled without running: refused, denied or failed its preflight.
    outcome: harness_services.ToolOutcome,
    permit: Permit,
};

/// Live authority and the permission request, one harness call at a time
/// per turn, so one person sees one harness prompt at a time. Null when
/// the turn was cancelled while it waited.
fn admit(self: *Turn, arena: Allocator, call: types.ToolCall, caller: []const u8) !?Admission {
    const deps = self.deps;
    const io = io_mod.getIo();
    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);
    var mode = self.mode;
    var grants: []const PermissionGrant = if (self.added_grants.items.len == 0) self.grants else try std.mem.concat(arena, PermissionGrant, &.{ self.grants, self.added_grants.items });

    var prepared: ?tooling_tool_admission.PreparedFileMutationCall = null;
    const is_file_mutation = file_mutation_contract.isToolName(call.name) and
        (deps.tool_registry.lookup(call.name) == null or deps.tool_registry.lookup(call.name).?.executor_kind != .host);
    if (is_file_mutation) switch (try tooling_tool_admission.prepareFileMutationCall(arena, call, .{
        .tool_registry = deps.tool_registry,
        .workspace_root = self.config.workspace_root,
        .access_scope = self.config.access_scope,
    })) {
        .tool_failure => |failure| return .{ .outcome = .{ .status = .failure, .output = failure } },
        .not_file_mutation => {},
        .prepared => |value| prepared = value,
    };

    var live: ?runtime_deps.LiveToolAuthority = null;
    if (deps.live_tool_authority != null) {
        const resolved = switch (try orchestrator.resolveLiveToolAuthority(deps, arena, call, self.config.workspace_root, self.advertised_dynamic_tool_names, if (prepared) |value| value.targetPath() else null)) {
            .resolved => |value| value,
            .tool_failure => |failure| return .{ .outcome = .{ .status = .refused, .output = failure } },
        };
        if (orchestrator.liveAuthorityRejectsExecution(resolved)) return .{ .outcome = .{
            .status = if (resolved.decision == .deny) .denied else .refused,
            .output = try arena.print("this agent's authority does not cover {s} now", .{call.name}),
        } };
        live = resolved.authority;
        mode = resolved.authority.permission_mode;
        grants = resolved.authority.grants;
    }

    const calls = try arena.alloc(types.ToolCall, 1);
    calls[0] = call;
    const review: permission_auto_classifier.ReviewTurnContext = .{
        .model = self.model,
        .pending_assistant = .{ .role = .assistant, .tool_calls = calls },
        .target_call_id = call.id,
        .origin = .harness,
        .harness_caller = caller,
        .credential = self.credential,
        .trusted_root_context = auto_classifier_context.rootUserRequestContext(self.root_user_intent_context) orelse "",
        .current_turn_untrusted_messages = self.current_turn_messages,
    };
    const outcome = (if (prepared) |*value|
        runtime_tool_admission.requestPreparedFileMutationPermissionTraced(deps, arena, call, value, review, mode, grants, live, self.advertised_dynamic_tool_names, self.config.workspace_root, self.trace)
    else
        runtime_tool_admission.requestToolPermissionTraced(deps, arena, call, review, mode, grants, live, null, self.advertised_dynamic_tool_names, self.advertised_dynamic_tools, self.config.workspace_root, self.trace)) catch |err| {
        if (err == error.Cancelled) return null;
        return err;
    };
    if (outcome.tool_failure) |failure| return .{ .outcome = .{ .status = .failure, .output = failure } };
    if (outcome.decision.isDenied()) {
        const reason = outcome.denial_reason orelse outcome.decision.denialReason() orelse .user_denied;
        const output = try orchestrator.permissionDeniedModelOutput(arena, call.name, reason, outcome);
        try runtime_tool_admission.recordRejectedToolCall(deps, arena, call, output, null);
        return .{ .outcome = .{ .status = .denied, .output = if (outcome.feedback) |feedback| try arena.print("{s}\n{s}", .{ output, feedback }) else output } };
    }
    const authority = outcome.execution_authority orelse return error.MissingToolExecutionAuthority;
    try checkAuthorityKind(deps, arena, call, authority, is_file_mutation and prepared != null);

    var execution_grants = grants;
    if (live == null) switch (outcome.decision) {
        .always => {
            const keep = self.grants_arena.allocator();
            if (authority == .file_mutation) {
                if (authority.file_mutation.grant_offer) |offer| try runtime_tool_admission.applyFrozenFileMutationSessionGrants(keep, deps, &self.added_grants, offer.grants);
            } else if (authority != .vision_paths) {
                const target = try deps.permission_target_for_call(deps.ctx, arena, call, self.advertised_dynamic_tool_names);
                try runtime_tool_admission.applyInitialSessionGrants(deps, keep, &self.added_grants, self.config.workspace_root, call, try keep.dupe(u8, target));
            }
            execution_grants = try std.mem.concat(arena, PermissionGrant, &.{ self.grants, self.added_grants.items });
        },
        .once => if (authority == .file_mutation) if (authority.file_mutation.grant_offer) |offer| {
            var once: std.ArrayList(PermissionGrant) = .empty;
            try once.appendSlice(arena, grants);
            try runtime_tool_admission.appendFrozenFileMutationGrants(arena, &once, offer.grants);
            execution_grants = once.items;
        },
        else => {},
    };
    return .{ .permit = .{ .authority = authority, .mode = mode, .grants = execution_grants, .live = live } };
}

/// The authority kinds the agent loop accepts for each kind of tool.
fn checkAuthorityKind(deps: *const AgentRuntimeDeps, arena: Allocator, call: types.ToolCall, authority: command_admission.ToolExecutionAuthority, is_file_mutation: bool) !void {
    if (try tooling_tool_admission.callUsesCommandAuthority(deps.tool_registry, arena, call)) {
        if (authority != .run_command) return error.InvalidRunCommandExecutionAuthority;
    } else if (is_file_mutation) {
        if (authority != .file_mutation) return error.InvalidFileMutationExecutionAuthority;
    } else if (std.mem.eql(u8, call.name, "vision")) {
        switch (authority) {
            .ordinary, .vision_paths => {},
            .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
        }
    } else if (authority != .ordinary) return error.UnexpectedCommandExecutionAuthority;
}

fn complete(context: *anyopaque, arena: Allocator, request: harness_services.CompletionRequest) anyerror!harness_services.CompletionOutcome {
    const self: *Turn = @ptrCast(@alignCast(context));
    const outcome = try runtime_text_completion.complete(arena, .{
        .observer = self.deps.observer,
        .stream_provider = self.deps.agent_stream_provider,
        .cooperative_pulse = self.deps.cooperative_transport_pulse,
        .credential = switch (self.credential) {
            .host_managed => .host_managed,
            .direct => |direct| .{ .direct = direct },
        },
        .session_id = self.session_id,
        .model = request.model orelse self.model,
        .retry_count = self.config.gateway_retry_count,
        .cancel_flag = self.config.cancel_flag,
        // Another model keeps the routing but not this one's options.
        .provider_options = if (request.model == null) self.provider_options else .{
            .prompt_caching = self.provider_options.prompt_caching,
            .provider_order = self.provider_options.provider_order,
            .provider_strict = self.provider_options.provider_strict,
        },
        .max_bytes = request.max_bytes,
        .trace_ctx = self.trace,
        .system = request.system,
        .user = request.prompt,
    });
    return switch (outcome) {
        .text => |text| .{ .text = text },
        .failed => |failure| .{ .failed = try arena.print("{s} {s}", .{ @tagName(failure.reason), failure.detail }) },
    };
}
