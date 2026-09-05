const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const managed_owner = @import("managed_owner.zig");
const model_contract = @import("model_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const terminal_wait_pulse_ms: u64 = 100;

pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

pub const ExecuteOptions = struct {
    caller_id: []const u8,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const ManagedExecutionResult = struct {
    success: bool,
    body: []u8,
};

pub const ApprovalResolveOptions = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]const u8 = null,
    timestamp_ms: i64,
};

pub const RecoveryState = enum(u8) { pending, complete };

pub const Runtime = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    managed: managed_owner.Owner,
    recovery_state: std.atomic.Value(RecoveryState) = .init(.pending),

    pub fn create(
        alloc: Allocator,
        sessions: *session_store.Store,
        root_id: []const u8,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        runtime.* = .{
            .alloc = alloc,
            .sessions = sessions,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .approvals = undefined,
            .authority_resolver = undefined,
            .managed = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
        };
        runtime.authority_resolver = .{
            .sessions = sessions,
            .root_id = runtime.root_id,
            .host = host_authority,
        };
        runtime.managed = runtime.managedOwnerValue();
        runtime.requestBackgroundRecovery(io_mod.milliTimestamp()) catch |err|
            debug_trace.logf(
                "subagent",
                "managed child recovery unavailable root_id={s} err={s}",
                .{ root_id, @errorName(err) },
            );
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.managed.deinit();
        self.approvals.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    pub fn rebind(
        self: *Runtime,
        sessions: *session_store.Store,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.sessions = sessions;
        self.host_authority = host_authority;
        self.child_runner.context = child_runner_context;
        self.authority_resolver.sessions = sessions;
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.sessions = sessions;
        self.managed.state_store.sessions = sessions;
        self.managed.services.context = self;
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = &self.approvals;
    }

    pub fn requestBackgroundRecovery(self: *Runtime, _: i64) !void {
        try self.managed.recoverInterrupted();
        self.recovery_state.store(.complete, .release);
    }

    pub fn recoveryState(self: *const Runtime) RecoveryState {
        return self.recovery_state.load(.acquire);
    }

    pub fn pendingApprovalRequest(
        self: *Runtime,
        alloc: Allocator,
    ) !?approval_registry.PendingRequest {
        return self.approvals.firstPendingRequest(alloc, self.root_id);
    }

    pub fn resolveApproval(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        return switch (try self.approvals.resolve(
            options.request_id,
            options.child_id,
            options.decision,
            options.feedback,
            options.timestamp_ms,
        )) {
            .accepted => .accepted,
            .rejected => .rejected,
        };
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
    ) u64 {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("model");
        hash.update(&.{0});
        hash.update(invocation_id);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.mem.readInt(u64, digest[0..8], .little) | 1;
    }

    pub fn executeManaged(
        self: *Runtime,
        alloc: Allocator,
        request: *model_contract.Request,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        _ = options.max_result_bytes;
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            self.issueOperationIdentity(options.invocation_id);
        const operation_id = try operationIdAlloc(
            alloc,
            options.invocation_id,
            identity_epoch,
        );
        defer alloc.free(operation_id);

        return switch (request.*) {
            .run, .message => blk: {
                if (!std.mem.eql(u8, options.caller_id, self.root_id)) {
                    break :blk self.encodeManaged(alloc, .{
                        .ok = false,
                        .error_code = "caller_unavailable",
                    });
                }
                var admitted = try self.admitManagedWork(
                    alloc,
                    request.*,
                    operation_id,
                    options,
                );
                defer admitted.deinit(alloc);
                switch (admitted) {
                    .rejected => |failure| {
                        break :blk self.encodeManaged(alloc, .{
                            .ok = false,
                            .error_code = failure.code,
                        });
                    },
                    .ready => |ready| {
                        _ = try self.managed.start(ready.child_id);
                        const result = try self.observeManagedState(
                            alloc,
                            ready.child_id,
                            operation_id,
                            options.cancel_flag,
                        );
                        break :blk result;
                    },
                    .completed => |completed| break :blk self.completeManagedResult(
                        alloc,
                        completed.child_id,
                        operation_id,
                        completed.observation,
                    ),
                }
            },
        };
    }

    fn managedOwnerValue(self: *Runtime) managed_owner.Owner {
        return .{
            .alloc = self.alloc,
            .sessions = self.sessions,
            .state_store = self.childStateStore(),
            .services = .{
                .context = self,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = &self.approvals,
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{
            .sessions = self.sessions,
            .parent_id = self.root_id,
        };
    }

    const ManagedAdmission = union(enum) {
        ready: struct { child_id: []u8 },
        completed: struct {
            child_id: []u8,
            observation: managed_owner.Observation,
        },
        rejected: struct {
            child_id: ?[]u8 = null,
            code: []const u8,
        },

        fn deinit(self: *ManagedAdmission, alloc: Allocator) void {
            switch (self.*) {
                .ready => |ready| alloc.free(ready.child_id),
                .completed => |completed| alloc.free(completed.child_id),
                .rejected => |failure| if (failure.child_id) |child_id| {
                    alloc.free(child_id);
                },
            }
            self.* = undefined;
        }
    };

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
    ) !ManagedAdmission {
        const fingerprint = model_contract.requestFingerprint(request);
        var lock = try self.managed.state_store.acquireLock(alloc);
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        if (registry.findByOperation(operation_id)) |existing| {
            const observed = child_state.Registry.operationFingerprint(
                existing.*,
                operation_id,
            ) orelse return managedAdmissionRejected(
                alloc,
                existing.id,
                "operation_conflict",
            );
            if (!std.mem.eql(u8, &observed, &fingerprint)) {
                return managedAdmissionRejected(
                    alloc,
                    existing.id,
                    "operation_conflict",
                );
            }
            try self.ensureManagedChildSession(
                alloc,
                existing.id,
                operation_id,
                options.defaults,
            );
            if (existing.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return .{ .completed = .{
                    .child_id = try alloc.dupe(u8, existing.id),
                    .observation = .{
                        .phase = existing.phase,
                        .outcome = existing.last_outcome,
                        .failure = existing.last_failure,
                    },
                } };
            }
            return managedAdmissionReady(alloc, existing.id);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
        );
        defer active.deinit(alloc);
        switch (request) {
            .run => {
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendOneOff(alloc, child_id, active);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(
                    alloc,
                    child_id,
                    active.id,
                    options.defaults,
                );
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
            .message => |message| {
                if (registry.findPersistent(message.agent)) |child| {
                    switch (child.phase) {
                        .running, .awaiting_approval => return managedAdmissionRejected(
                            alloc,
                            child.id,
                            "child_busy",
                        ),
                        .finished => return managedAdmissionRejected(
                            alloc,
                            child.id,
                            "child_unavailable",
                        ),
                        .idle, .interrupted => {},
                    }
                    const started = try registry.startPersistentWork(
                        alloc,
                        message.agent,
                        message.instructions,
                        active,
                    );
                    try self.managed.state_store.save(alloc, registry);
                    return managedAdmissionReady(alloc, started.id);
                }
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                );
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(
                    alloc,
                    child_id,
                    active.id,
                    options.defaults,
                );
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
        }
    }

    fn ensureManagedChildSession(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        defaults: Defaults,
    ) !void {
        var state = try freshChildState(
            alloc,
            child_id,
            self.sessions.workspace_root,
            work_id,
            defaults,
        );
        defer state.deinit(alloc);
        if (self.sessions.startWritableSession(alloc, state)) |writable_value| {
            var writable = writable_value;
            writable.log.park();
            writable.deinit(alloc);
        } else |err| switch (err) {
            error.SessionAlreadyExists => {},
            else => return err,
        }
        try self.childStateStore().markChildSession(alloc, child_id);
    }

    fn observeManagedState(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !ManagedExecutionResult {
        while (true) {
            if (cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    self.managed.cancel(child_id) catch |err| switch (err) {
                        error.ChildUnavailable => {},
                    };
                    return error.Cancelled;
                }
            }
            const observation = self.managed.wait(child_id, .{
                .clock = .awake,
                .raw = .fromMilliseconds(terminal_wait_pulse_ms),
            }) catch |err| return self.encodeManaged(alloc, .{
                .ok = false,
                .error_code = switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ChildUnavailable => "child_unavailable",
                    error.StateUnavailable => "state_unavailable",
                },
            });
            switch (observation.phase) {
                .running, .awaiting_approval => continue,
                .idle, .finished, .interrupted => {},
            }
            return self.completeManagedResult(alloc, child_id, work_id, observation);
        }
    }

    fn completeManagedResult(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        observation: managed_owner.Observation,
    ) !ManagedExecutionResult {
        const result = try self.managedResultText(alloc, child_id, work_id);
        defer if (result) |text| alloc.free(text);
        const failure_text = if (observation.outcome == .failed)
            try formatFailedResult(alloc, if (observation.failure) |*failure| failure.view() else null, result)
        else
            null;
        defer if (failure_text) |text| alloc.free(text);
        return self.encodeManaged(alloc, terminalResult(observation, failure_text orelse result));
    }

    fn managedResultText(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
    ) !?[]u8 {
        var state = self.sessions.loadReadOnly(alloc, child_id) catch return null;
        defer state.deinit(alloc);
        const text = assistantTextForWork(state.history, work_id) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, text));
    }

    fn encodeManaged(
        self: *Runtime,
        alloc: Allocator,
        result: model_contract.Result,
    ) !ManagedExecutionResult {
        _ = self;
        return .{
            .success = result.ok,
            .body = try model_contract.encodeResultAlloc(alloc, result),
        };
    }
};

fn operationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "fxop:2:m:{d}:{s}", .{ epoch, &hex });
}

test "internal operation identity is deterministic and invocation-bound" {
    const alloc = std.testing.allocator;
    const first = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(first);
    const replay = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(replay);
    const changed = try operationIdAlloc(alloc, "call-2", 41);
    defer alloc.free(changed);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try std.testing.expect(std.mem.startsWith(u8, first, "fxop:2:m:41:"));
}

fn formatFailedResult(alloc: Allocator, failure: ?[]const u8, partial: ?[]const u8) ![]u8 {
    const reason = failure orelse "failure reason unavailable";
    const text = partial orelse "";
    return std.fmt.allocPrint(alloc, "Subagent failed: {s}. Earlier tool calls may have completed; their effects are not rolled back.{s}{s}", .{
        reason,
        if (text.len > 0) "\n\nPartial result:\n" else "",
        text,
    });
}

test "subagent failure result distinguishes runtime cause from retained partial text" {
    const alloc = std.testing.allocator;
    const text = try formatFailedResult(alloc, "agent_turn_failed: SessionCommitFailed", "one edit completed");
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "SessionCommitFailed") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Partial result:\none edit completed"));
    const legacy = try formatFailedResult(alloc, null, "");
    defer alloc.free(legacy);
    try std.testing.expect(std.mem.find(u8, legacy, "failure reason unavailable") != null);
    try std.testing.expect(std.mem.find(u8, legacy, "Partial result:") == null);
}

fn terminalResult(
    observation: managed_owner.Observation,
    result: ?[]const u8,
) model_contract.Result {
    return switch (observation.outcome orelse return .{
        .ok = false,
        .result = result,
        .error_code = "child_result_unavailable",
    }) {
        .completed => if (result != null) .{
            .ok = true,
            .result = result,
        } else .{
            .ok = false,
            .error_code = "child_result_unavailable",
        },
        .failed => .{
            .ok = false,
            .result = result,
            .error_code = "child_failed",
        },
        .cancelled => .{
            .ok = false,
            .result = result,
            .error_code = "child_cancelled",
        },
        .interrupted => .{
            .ok = false,
            .result = result,
            .error_code = "child_interrupted",
        },
    };
}

test "terminal result projects every managed outcome without a lifecycle phase" {
    const completed = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, "done");
    try std.testing.expect(completed.ok);
    try std.testing.expectEqualStrings("done", completed.result.?);
    try std.testing.expect(completed.error_code == null);

    const cases = [_]struct {
        outcome: child_state.Outcome,
        error_code: []const u8,
    }{
        .{ .outcome = .failed, .error_code = "child_failed" },
        .{ .outcome = .cancelled, .error_code = "child_cancelled" },
        .{ .outcome = .interrupted, .error_code = "child_interrupted" },
    };
    for (cases) |case| {
        const projected = terminalResult(.{
            .phase = .interrupted,
            .outcome = case.outcome,
        }, "partial");
        try std.testing.expect(!projected.ok);
        try std.testing.expectEqualStrings("partial", projected.result.?);
        try std.testing.expectEqualStrings(case.error_code, projected.error_code.?);
    }

    const missing = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, null);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("child_result_unavailable", missing.error_code.?);
}

fn managedAdmissionReady(
    alloc: Allocator,
    child_id: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id) } };
}

fn managedAdmissionRejected(
    alloc: Allocator,
    child_id: ?[]const u8,
    code: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .rejected = .{
        .child_id = if (child_id) |value| try alloc.dupe(u8, value) else null,
        .code = code,
    } };
}

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const message = switch (request) {
        .run => |value| value.task,
        .message => |value| value.message,
    };
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const owned_message = try alloc.dupe(u8, message);
    errdefer alloc.free(owned_message);
    const root_context = if (options.root_user_intent_context.len == 0)
        &.{}
    else
        try alloc.dupe(u8, options.root_user_intent_context);
    errdefer if (root_context.len > 0) alloc.free(root_context);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .message = owned_message,
        .root_user_intent_context = @constCast(root_context),
        .root_user_messages = try cloneStrings(alloc, options.root_user_messages),
        .root_user_evidence_complete = options.root_user_evidence_complete,
        .permission_mode = options.parent_permission_mode,
        .created_at_ms = options.timestamp_ms,
    };
}

fn assistantTextForWork(
    history: []const types.HistoryTurn,
    work_id: []const u8,
) ?[]const u8 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const candidate = history[index];
        const candidate_work_id = session.historyTurnWorkId(candidate) orelse continue;
        if (!std.mem.eql(u8, candidate_work_id, work_id)) continue;
        return switch (candidate) {
            .assistant => |value| value.assistant,
            .interrupted => |value| value.assistant orelse "",
            .compacted_summary => null,
        };
    }
    return null;
}

fn freshChildState(
    alloc: Allocator,
    child_id: []const u8,
    workspace_root: []const u8,
    work_id: []const u8,
    defaults: Defaults,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try alloc.dupe(u8, child_id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, defaults.model);
    errdefer alloc.free(model);
    const last_subagent_work_id = try alloc.dupe(u8, work_id);
    errdefer alloc.free(last_subagent_work_id);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = defaults.conversation_language,
        .preferences = .{
            .provider = defaults.provider,
            .model = model,
            .effort = defaults.effort,
            .fast_mode = defaults.fast_mode,
        },
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .last_subagent_work_id = last_subagent_work_id,
        .subagent_child = true,
    };
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
        .integration_names = snapshot.integrations,
        .authority_generation = if (snapshot.mcp_view) |view|
            mcp_access.authorityGeneration(view)
        else
            0,
        .mcp_view = snapshot.mcp_view,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(
        self: ModePolicy,
        tool_set: tool_set_contract.ToolSet,
        tool_name: []const u8,
    ) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(
                tool_set,
                active.id,
                tool_name,
            ),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthority(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
) !authority.HostAuthority {
    return captureHostAuthorityWithMcpView(
        alloc,
        policy,
        integration_names,
        rules,
        grants,
        .{},
        null,
    );
}

pub fn captureHostAuthorityWithMcpView(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    return authority.HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        tool_names.items,
        integration_names,
        rules,
        grants,
        permission_state,
        mcp_view,
    );
}
