const std = @import("std");
const builtin = @import("builtin");
const approval_persistence = @import("approval_persistence.zig");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const create_store = @import("create_store.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const manager_mod = @import("manager.zig");
const tool_result = @import("tool_result.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const inspect_wait_external_poll_ms: i64 = 100;

const TargetAuthorizationTestHook = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque) void,
};

const TestHooks = struct {
    var after_target_authorization: ?TargetAuthorizationTestHook = null;
};

fn runAfterTargetAuthorizationTestHook() void {
    if (comptime builtin.is_test) {
        const hook = TestHooks.after_target_authorization orelse return;
        hook.run_fn(hook.context);
    }
}

pub const RecoveryState = enum(u8) {
    pending,
    scheduled,
    running,
    deferred,
    complete,
};

const RecoveryTrigger = enum {
    automatic,
    explicit,
};

const RecoveryStartDecision = enum {
    schedule,
    start,
    wait,
    no_effect,
};

const RecoveryFinishOutcome = enum {
    fully_reconciled,
    incomplete,
    failed,
};

fn decideRecoveryStart(
    state: RecoveryState,
    trigger: RecoveryTrigger,
) RecoveryStartDecision {
    return switch (state) {
        .pending => switch (trigger) {
            .automatic => .schedule,
            .explicit => .start,
        },
        .scheduled, .running => switch (trigger) {
            .automatic => .no_effect,
            .explicit => .wait,
        },
        .deferred => switch (trigger) {
            .automatic => .no_effect,
            .explicit => .start,
        },
        .complete => .no_effect,
    };
}

fn recoveryStateAfterFinish(outcome: RecoveryFinishOutcome) RecoveryState {
    return switch (outcome) {
        .fully_reconciled => .complete,
        .incomplete, .failed => .deferred,
    };
}

pub const BackgroundRecoveryError = error{ThreadSpawnFailed};

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
    relationship_approval_id: ?[]const u8 = null,
    identity_epoch: u64 = 0,
};

pub const MessageSendOptions = struct {
    caller_id: []const u8,
    invocation_id: []const u8,
    child_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
};

pub const HumanCommandOptions = struct {
    invocation_id: []const u8,
    defaults: Defaults,
    expected_generation: ?u64 = null,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
};

pub const ApprovalResolveOptions = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]const u8 = null,
    timestamp_ms: i64,
};

fn buildHumanQueuedRootUserContext(
    alloc: Allocator,
    command: domain.Command,
) !?[]u8 {
    const current_request = humanQueuedRootUserMessage(command);
    return if (current_request) |request|
        try auto_classifier_context.buildCanonicalRootUserContext(
            alloc,
            request,
            &.{},
        )
    else
        null;
}

fn humanQueuedRootUserMessage(command: domain.Command) ?[]const u8 {
    return switch (command) {
        .create => |create| create.prompt,
        .message => |message| switch (message) {
            .send => |send| send.content,
            .milestone => null,
        },
        .inspect, .relationship, .configure, .lifecycle => null,
    };
}

const ModelCommandOutcome = union(enum) {
    result: manager_mod.Result,
    relationship_approval: domain.RelationshipCommand,
    adapter_failure: struct {
        child_id: ?[]const u8,
        code: []const u8,
        retryable: bool = false,
    },

    fn deinit(self: *ModelCommandOutcome, alloc: Allocator) void {
        switch (self.*) {
            .result => |*result| result.deinit(alloc),
            .relationship_approval, .adapter_failure => {},
        }
        self.* = undefined;
    }
};

pub const Runtime = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    manager: manager_mod.Manager,
    durable_approvals: approval_persistence.DurableRegistry,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    owner: execution.Owner,
    recovery_mutex: std.Io.Mutex = .init,
    recovery_condition: std.Io.Condition = .init,
    recovery_thread: ?std.Thread = null,
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
            .manager = .{ .sessions = sessions },
            .durable_approvals = .{ .alloc = alloc, .sessions = sessions },
            .approvals = undefined,
            .authority_resolver = undefined,
            .owner = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
            .persistence = runtime.durable_approvals.interface(),
        };
        runtime.authority_resolver = .{
            .sessions = sessions,
            .host = host_authority,
        };
        runtime.owner = runtime.ownerValue();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.recovery_thread) |thread| thread.join();
        self.recovery_thread = null;
        const had_owned_work = self.owner.started_any;
        self.owner.deinit();
        if (had_owned_work) {
            var recovery_owner = self.ownerValue();
            _ = recovery_owner.recoverTree(
                self.root_id,
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "host exit recovery failed root_id={s} outcome={s}",
                    .{ self.root_id, @errorName(err) },
                );
            };
            recovery_owner.deinit();
        }
        self.approvals.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Refreshes borrowed host pointers after an embedding runtime moves.
    /// Callers must do this before any child work starts.
    pub fn rebind(
        self: *Runtime,
        sessions: *session_store.Store,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        std.debug.assert(self.owner.slots.items.len == 0);
        std.debug.assert(self.recovery_thread == null);
        self.sessions = sessions;
        self.manager.sessions = sessions;
        self.durable_approvals.sessions = sessions;
        self.authority_resolver.sessions = sessions;
        self.authority_resolver.host = self.host_authority;
        self.owner.sessions = sessions;
        self.child_runner.context = child_runner_context;
        self.host_authority = host_authority;
        self.authority_resolver.host = host_authority;
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        alloc: Allocator,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
    ) !u64 {
        return issueManagerOperationIdentity(
            alloc,
            self.sessions,
            self.root_id,
            self.manager.options.child_store,
            invocation_id,
            source,
        );
    }

    fn ownerValue(self: *Runtime) execution.Owner {
        return .{
            .alloc = self.alloc,
            .sessions = self.sessions,
            .manager = &self.manager,
            .services = .{
                .context = self,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .live_authority = &self.authority_resolver,
            .approval_registry = &self.approvals,
            .retirement_root_id = self.root_id,
            .notification_clock = .{
                .now_fn = notificationNow,
            },
            .notification_poller = .{
                .context = self,
                .poll_fn = pollNotification,
            },
        };
    }

    fn notificationNow(_: ?*anyopaque) i64 {
        return io_mod.milliTimestamp();
    }

    fn pollNotification(
        raw: ?*anyopaque,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse
            return error.StoreUnavailable));
        var delivery_manager = communication_manager.Manager{
            .sessions = self.sessions,
            .child_store_options = self.manager.options.child_store,
        };
        return delivery_manager.poll(alloc, child_id, work_id, now_ms);
    }

    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: ExecuteOptions,
    ) ![]u8 {
        if (command.* == .inspect) {
            return self.executeModelInspection(alloc, command.*, options);
        }
        if (command.* == .create and
            !try self.callerMayCreate(alloc, options.caller_id))
        {
            return boundedFailureAlloc(
                alloc,
                options.invocation_id,
                null,
                "invalid_state",
                false,
                options.max_result_bytes,
            );
        }
        if (!try self.admitModelCommand(
            alloc,
            command,
            options.caller_id,
            options.parent_permission_mode,
        )) {
            return boundedFailureAlloc(
                alloc,
                options.invocation_id,
                commandTarget(command.*),
                "permission_escalation",
                false,
                options.max_result_bytes,
            );
        }
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .model);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .model,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);

        var outcome = try self.executeModelMutation(
            alloc,
            command,
            options,
            operation_id,
            identity_epoch,
            identity_admitted,
        );
        defer outcome.deinit(alloc);
        self.finishModelOutcome(alloc, operation_id, &outcome);
        return switch (outcome) {
            .result => |result| self.encodeResult(
                alloc,
                operation_id,
                result,
                options.max_result_bytes,
                null,
            ),
            .relationship_approval => |relationship| encodeRelationshipApprovalIntent(
                alloc,
                operation_id,
                relationship,
                options.max_result_bytes,
            ),
            .adapter_failure => |failure| boundedFailureAlloc(
                alloc,
                operation_id,
                failure.child_id,
                failure.code,
                failure.retryable,
                options.max_result_bytes,
            ),
        };
    }

    fn executeModelInspection(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        options: ExecuteOptions,
    ) ![]u8 {
        std.debug.assert(command == .inspect);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .model,
            0,
        );
        defer alloc.free(operation_id);
        self.recoverIfNeeded(options.timestamp_ms);
        const target_id = command.inspect.id;
        const wait = command.inspect.wait;
        const deadline = if (wait) |requested|
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromMilliseconds(@intCast(requested.timeout_ms)),
            })
        else
            null;

        while (true) {
            var waiter = execution.ChildWaiter{ .child_id = target_id };
            if (wait != null) try self.owner.registerChildWaiter(&waiter);
            defer if (waiter.registered) self.owner.unregisterChildWaiter(&waiter);

            if (!std.mem.eql(u8, options.caller_id, self.root_id) and
                !try self.isAttached(self.root_id, options.caller_id))
            {
                return tool_result.failureAlloc(
                    alloc,
                    operation_id,
                    null,
                    "rejected",
                    "caller_unavailable",
                    false,
                    null,
                );
            }
            if (!std.mem.eql(u8, target_id, options.caller_id) and
                !try self.isAttached(options.caller_id, target_id))
            {
                return tool_result.failureAlloc(
                    alloc,
                    operation_id,
                    target_id,
                    "rejected",
                    "child_unavailable",
                    false,
                    null,
                );
            }
            runAfterTargetAuthorizationTestHook();

            var result = try self.manager.execute(alloc, command, .{
                .actor_id = options.caller_id,
                .target_authorization = .{ .attached_to_root = self.root_id },
                .timestamp_ms = options.timestamp_ms,
            });
            defer result.deinit(alloc);

            const requested_wait = wait orelse return self.encodeResult(
                alloc,
                operation_id,
                result,
                options.max_result_bytes,
                null,
            );
            const inspection = switch (result) {
                .inspection => |*value| value,
                .receipt => unreachable,
                .failure => return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    null,
                ),
            };
            if (domain.inspectWaitSatisfied(
                requested_wait,
                inspection.generation,
                inspection.status.?,
            )) {
                return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    null,
                );
            }

            const remaining = deadline.?.durationFromNow(io_mod.getIo());
            if (remaining.raw.nanoseconds <= 0) {
                return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    "wait_timed_out",
                );
            }
            const poll_duration = std.Io.Duration.fromMilliseconds(
                inspect_wait_external_poll_ms,
            );
            _ = try waiter.wait(.{
                .clock = .awake,
                .raw = .{
                    .nanoseconds = @min(
                        remaining.raw.nanoseconds,
                        poll_duration.nanoseconds,
                    ),
                },
            });
        }
    }

    fn executeModelMutation(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: ExecuteOptions,
        operation_id: []const u8,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !ModelCommandOutcome {
        if (command.* == .message and command.message == .send) {
            var result = try self.sendMessageWithOperation(
                alloc,
                command.*,
                operation_id,
                options.caller_id,
                options.root_user_intent_context,
                options.root_user_messages,
                options.root_user_evidence_complete,
                options.timestamp_ms,
                .model,
                identity_epoch,
                identity_admitted,
            );
            normalizeRetiredResult(identity_admitted, &result);
            return .{ .result = result };
        }
        if (identity_admitted and
            !std.mem.eql(u8, options.caller_id, self.root_id) and
            !try self.isAttached(self.root_id, options.caller_id))
        {
            return .{ .result = .{ .failure = .{
                .code = .caller_unavailable,
            } } };
        }

        const target = commandTarget(command.*);
        if (target) |target_id| {
            const relationship_external = switch (command.*) {
                .relationship => |value| value.action != .detach,
                else => false,
            };
            if (identity_admitted and
                !relationship_external and
                !std.mem.eql(u8, target_id, options.caller_id) and
                !try self.isAttached(options.caller_id, target_id))
            {
                return .{ .result = .{ .failure = .{
                    .code = .child_unavailable,
                } } };
            }
        }
        if (command.* == .create or command.* == .configure or command.* == .lifecycle) {
            runAfterTargetAuthorizationTestHook();
        }

        if (!try self.admitModelCommand(
            alloc,
            command,
            options.caller_id,
            options.parent_permission_mode,
        )) {
            return .{ .adapter_failure = .{
                .child_id = commandTarget(command.*),
                .code = "permission_escalation",
            } };
        }

        if (command.* == .create) try applyCreateDefaults(alloc, &command.create, options.defaults);
        var context = manager_mod.Context{
            .actor_id = options.caller_id,
            .root_user_intent_context = options.root_user_intent_context,
            .root_user_messages = options.root_user_messages,
            .root_user_evidence_complete = options.root_user_evidence_complete,
            .operation_id = operation_id,
            .operation_identity_source = .model,
            .operation_identity_epoch = identity_epoch,
            .operation_identity_admitted = identity_admitted,
            .timestamp_ms = options.timestamp_ms,
        };
        if (command.* == .relationship) {
            const relationship = command.relationship;
            if (relationship.action != .detach and
                options.relationship_approval_id == null)
            {
                if (!identity_admitted) {
                    return .{ .result = .{ .failure = .{
                        .code = .operation_replay_expired,
                    } } };
                }
                const parent_id = relationship.parent_id orelse options.caller_id;
                self.approvals.registerRelationship(
                    operation_id,
                    relationship.id,
                    self.root_id,
                    relationship.action,
                    parent_id,
                    operation_id,
                    relationshipApprovalLabel(relationship.action),
                    identity_admitted,
                    options.timestamp_ms,
                ) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (err == error.CapacityExceeded) {
                        return .{ .adapter_failure = .{
                            .child_id = relationship.id,
                            .code = "communication_capacity_exceeded",
                        } };
                    }
                    return .{ .adapter_failure = .{
                        .child_id = relationship.id,
                        .code = "approval_registration_failed",
                    } };
                };
                return .{ .relationship_approval = relationship };
            }
            context.relationship_authorization = if (relationship.action == .detach)
                .none
            else if (options.relationship_approval_id) |approval_id|
                .{ .approval = approval_id }
            else
                .none;
        }

        var result = try self.executeAuthorizedCommand(
            alloc,
            command.*,
            context,
            options.defaults,
        );
        normalizeRetiredResult(identity_admitted, &result);
        return .{ .result = result };
    }

    /// Applies the model-tool-only child permission boundary. Root callers use
    /// the current turn's effective mode; child callers are resolved from live
    /// control state on every check.
    pub fn admitModelCommand(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        caller_id: []const u8,
        root_permission_mode: types.PermissionMode,
    ) authority.Error!bool {
        const requested: ?types.PermissionMode = switch (command.*) {
            .create => |create_command| if (create_command.permission_mode_explicit)
                create_command.configuration.permission_mode
            else
                null,
            .configure => |configure| configure.permission_mode orelse return true,
            .inspect, .message, .relationship, .lifecycle => return true,
        };
        const parent_permission_mode = if (std.mem.eql(u8, caller_id, self.root_id))
            root_permission_mode
        else blk: {
            var snapshot = try self.authority_resolver.resolve(alloc, caller_id);
            defer snapshot.deinit(alloc);
            break :blk snapshot.permission_mode;
        };
        const admitted = authority.admitChildPermission(
            parent_permission_mode,
            requested,
        ) catch return false;
        if (command.* == .create and !command.create.permission_mode_explicit) {
            command.create.configuration.permission_mode = admitted;
        }
        return true;
    }

    fn callerMayCreate(
        self: *Runtime,
        alloc: Allocator,
        caller_id: []const u8,
    ) error{OutOfMemory}!bool {
        if (std.mem.eql(u8, caller_id, self.root_id)) return true;
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            caller_id,
            self.manager.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = caller_id,
        };
        var record = (store.loadOptional(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        }) orelse return false;
        defer record.deinit(alloc);
        return record.mode != .one_off;
    }

    /// Typed human adapter for the same canonical command/effect path used by
    /// the model tool. Human relationship submission is itself the explicit
    /// authorization; all validation and state mutation remain manager-owned.
    pub fn executeHumanCommand(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: HumanCommandOptions,
    ) !manager_mod.Result {
        if (command.* == .inspect) {
            self.recoverIfNeeded(options.timestamp_ms);
            const target_id = command.inspect.id;
            if (!std.mem.eql(u8, target_id, self.root_id) and
                !try self.isAttached(self.root_id, target_id))
            {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
            runAfterTargetAuthorizationTestHook();
            return self.manager.execute(alloc, command.*, .{
                .actor_id = self.root_id,
                .target_authorization = .{ .attached_to_root = self.root_id },
                .timestamp_ms = options.timestamp_ms,
            });
        }
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .human);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .human,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);

        var result = try self.executeHumanMutation(
            alloc,
            command,
            options,
            operation_id,
            identity_epoch,
            identity_admitted,
        );
        normalizeRetiredResult(identity_admitted, &result);
        self.finishOperationResult(alloc, operation_id, &result);
        return result;
    }

    fn executeHumanMutation(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: HumanCommandOptions,
        operation_id: []const u8,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !manager_mod.Result {
        const owned_root_user_intent_context = try buildHumanQueuedRootUserContext(
            alloc,
            command.*,
        );
        defer if (owned_root_user_intent_context) |context| alloc.free(context);
        const root_user_intent_context = owned_root_user_intent_context orelse "";
        const root_user_message = humanQueuedRootUserMessage(command.*);
        const root_user_messages: []const []const u8 = if (root_user_message) |message|
            &.{message}
        else
            &.{};
        if (command.* == .message and command.message == .send) {
            return self.sendMessageWithOperation(
                alloc,
                command.*,
                operation_id,
                self.root_id,
                root_user_intent_context,
                root_user_messages,
                root_user_message != null,
                options.timestamp_ms,
                .human,
                identity_epoch,
                identity_admitted,
            );
        }

        if (commandTarget(command.*)) |target_id| {
            const relationship_external = command.* == .relationship;
            if (identity_admitted and
                !relationship_external and
                !std.mem.eql(u8, target_id, self.root_id) and
                !try self.isAttached(self.root_id, target_id))
            {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
        }
        if (command.* == .configure or command.* == .lifecycle) {
            runAfterTargetAuthorizationTestHook();
        }

        if (command.* == .create) try applyCreateDefaults(alloc, &command.create, options.defaults);
        return self.executeAuthorizedCommand(
            alloc,
            command.*,
            .{
                .actor_id = self.root_id,
                .root_user_intent_context = root_user_intent_context,
                .root_user_messages = root_user_messages,
                .root_user_evidence_complete = root_user_message != null,
                .operation_id = operation_id,
                .operation_identity_source = .human,
                .operation_identity_epoch = identity_epoch,
                .operation_identity_admitted = identity_admitted,
                .expected_generation = options.expected_generation,
                .relationship_authorization = if (command.* == .relationship and
                    command.relationship.action != .detach)
                    .direct
                else
                    .none,
                .timestamp_ms = options.timestamp_ms,
            },
            options.defaults,
        );
    }

    pub fn resolveApproval(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        const resolved = self.approvals.resolve(
            options.request_id,
            options.child_id,
            options.decision,
            options.feedback,
            options.timestamp_ms,
        ) catch |err| {
            if (self.relationshipApprovalIsTerminal(
                options.child_id,
                options.request_id,
            ) catch false) {
                self.completeOperationIdentity(options.request_id) catch
                    return error.CommitFailed;
            }
            return err;
        };
        switch (resolved) {
            .accepted => {
                if (options.decision == .deny) {
                    self.completeOperationIdentity(options.request_id) catch
                        return error.CommitFailed;
                }
                return .accepted;
            },
            .rejected => return .rejected,
            .relationship_ready => return self.continueApprovedRelationship(
                options,
            ),
        }
    }

    fn continueApprovedRelationship(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        var continuation = self.durable_approvals.loadRelationshipContinuation(
            options.child_id,
            options.request_id,
        ) catch |err| return self.relationshipContinuationLoadFailed(
            options,
            err,
        );
        defer continuation.deinit(self.alloc);

        if (!std.mem.eql(u8, continuation.root_id, self.root_id) or
            !std.mem.eql(u8, continuation.operation_id, options.request_id))
        {
            return self.terminalizeRelationshipContinuation(
                options,
                "identity_mismatch",
            );
        }
        const identity = tool_result.parseBoundOperationId(
            continuation.operation_id,
        ) orelse return self.terminalizeRelationshipContinuation(
            options,
            "invalid_operation_identity",
        );
        if (identity.authority != .manager or
            identity.source != .model or identity.epoch == 0)
        {
            return self.terminalizeRelationshipContinuation(
                options,
                "invalid_operation_identity",
            );
        }
        if (continuation.status == .consumed) {
            return self.finishAppliedRelationship(
                options,
                continuation.action,
            );
        }
        if (continuation.status != .allowed_once) {
            return self.terminalizeRelationshipContinuation(
                options,
                "identity_mismatch",
            );
        }

        const identity_admitted = self.operationIdentityOutstanding(
            self.alloc,
            continuation.operation_id,
        ) catch |err| {
            return self.releaseRelationshipContinuation(
                options,
                if (err == error.OutOfMemory)
                    error.OutOfMemory
                else
                    error.CommitFailed,
                @errorName(err),
            );
        };
        if (!identity_admitted) {
            return self.terminalizeRelationshipContinuation(
                options,
                "operation_identity_retired",
            );
        }

        var command = domain.validateCommand(self.alloc, .{ .relationship = .{
            .action = continuation.action,
            .id = continuation.child_id,
            .parent_id = continuation.prospective_parent_id,
        } }) catch |err| {
            return if (err == error.OutOfMemory)
                self.releaseRelationshipContinuation(
                    options,
                    error.OutOfMemory,
                    @errorName(err),
                )
            else
                self.terminalizeRelationshipContinuation(
                    options,
                    @errorName(err),
                );
        };
        defer command.deinit(self.alloc);
        var result = self.manager.execute(self.alloc, command, .{
            .actor_id = self.root_id,
            .operation_id = continuation.operation_id,
            .operation_identity_source = identity.source,
            .operation_identity_epoch = identity.epoch,
            .operation_identity_admitted = true,
            .relationship_authorization = .{
                .approval = options.request_id,
            },
            .timestamp_ms = options.timestamp_ms,
        }) catch {
            return self.releaseRelationshipContinuation(
                options,
                error.OutOfMemory,
                "OutOfMemory",
            );
        };
        defer result.deinit(self.alloc);
        switch (result) {
            .receipt => {
                var observed = self.durable_approvals.loadRelationshipContinuation(
                    options.child_id,
                    options.request_id,
                ) catch |err| return self.relationshipContinuationLoadFailed(
                    options,
                    err,
                );
                defer observed.deinit(self.alloc);
                if (observed.status != .consumed) {
                    return self.releaseRelationshipContinuation(
                        options,
                        error.CommitFailed,
                        "approval_not_consumed",
                    );
                }
                return self.finishAppliedRelationship(
                    options,
                    continuation.action,
                );
            },
            .failure => |failure| return if (failure.retryable)
                self.releaseRelationshipContinuation(
                    options,
                    error.CommitFailed,
                    @tagName(failure.code),
                )
            else
                self.terminalizeRelationshipContinuation(
                    options,
                    @tagName(failure.code),
                ),
            .inspection => unreachable,
        }
    }

    fn finishAppliedRelationship(
        self: *Runtime,
        options: ApprovalResolveOptions,
        action: domain.RelationshipAction,
    ) approval_registry.Error!approval_registry.ResolveResult {
        try self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .succeeded,
            options.timestamp_ms,
        );
        self.retireResolvedRelationshipIdentity(
            options.request_id,
            options.child_id,
        );
        debug_trace.logf(
            "subagent",
            "relationship approval applied request_id={s} child_id={s} action={s}",
            .{
                options.request_id,
                options.child_id,
                @tagName(action),
            },
        );
        return .accepted;
    }

    fn relationshipContinuationLoadFailed(
        self: *Runtime,
        options: ApprovalResolveOptions,
        err: approval_persistence.Error,
    ) approval_registry.Error {
        if (!relationshipContinuationLoadRetryable(err)) {
            return self.terminalizeRelationshipContinuation(
                options,
                @errorName(err),
            );
        }
        return self.releaseRelationshipContinuation(
            options,
            if (err == error.OutOfMemory)
                error.OutOfMemory
            else
                error.CommitFailed,
            @errorName(err),
        );
    }

    fn releaseRelationshipContinuation(
        self: *Runtime,
        options: ApprovalResolveOptions,
        result_error: approval_registry.Error,
        reason: []const u8,
    ) approval_registry.Error {
        self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .retryable_failure,
            options.timestamp_ms,
        ) catch |err| return err;
        debug_trace.logf(
            "subagent",
            "relationship approval deferred request_id={s} child_id={s} outcome={s}",
            .{ options.request_id, options.child_id, reason },
        );
        return result_error;
    }

    fn terminalizeRelationshipContinuation(
        self: *Runtime,
        options: ApprovalResolveOptions,
        reason: []const u8,
    ) approval_registry.Error {
        self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .terminal_failure,
            options.timestamp_ms,
        ) catch |err| return err;
        self.retireResolvedRelationshipIdentity(
            options.request_id,
            options.child_id,
        );
        debug_trace.logf(
            "subagent",
            "relationship approval invalidated request_id={s} child_id={s} outcome={s}",
            .{ options.request_id, options.child_id, reason },
        );
        return error.StaleRequest;
    }

    fn retireResolvedRelationshipIdentity(
        self: *Runtime,
        request_id: []const u8,
        child_id: []const u8,
    ) void {
        self.completeOperationIdentity(request_id) catch |err| {
            debug_trace.logf(
                "subagent",
                "relationship approval identity cleanup failed request_id={s} child_id={s} outcome={s}",
                .{ request_id, child_id, @errorName(err) },
            );
        };
    }

    fn relationshipApprovalIsTerminal(
        self: *Runtime,
        child_id: []const u8,
        request_id: []const u8,
    ) !bool {
        const alloc = self.alloc;
        var capability = try self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var ledger = (try store.loadOptional(alloc)) orelse return false;
        defer ledger.deinit(alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            request_id,
        ) orelse return false;
        const relationship = approval.relationship orelse return false;
        if (!std.mem.eql(u8, relationship.operation_id, request_id)) {
            return false;
        }
        return switch (approval.status) {
            .denied, .cancelled, .stale, .consumed => true,
            .pending, .allowed_once, .allowed_always => false,
        };
    }

    /// Completes restart reconciliation for an explicit subagent operation.
    /// An admitted background attempt finishes first; a deferred attempt may
    /// then be retried once by this caller. Recovery never starts child work.
    pub fn reconcileAfterRestart(
        self: *Runtime,
        timestamp_ms: i64,
    ) execution.RecoveryError!execution.RecoveryReport {
        const io = io_mod.getIo();
        self.recovery_mutex.lockUncancelable(io);
        defer self.recovery_mutex.unlock(io);

        while (true) {
            const state = self.recovery_state.load(.acquire);
            switch (decideRecoveryStart(state, .explicit)) {
                .no_effect => return .{},
                .wait => {
                    std.debug.assert(state == .scheduled);
                    self.recovery_condition.waitUncancelable(io, &self.recovery_mutex);
                },
                .start => {
                    switch (state) {
                        .pending => if (self.recovery_state.cmpxchgStrong(
                            .pending,
                            .running,
                            .acq_rel,
                            .acquire,
                        ) != null) continue,
                        .deferred => self.recovery_state.store(.running, .release),
                        else => unreachable,
                    }
                    return self.runRecoveryLocked(timestamp_ms);
                },
                .schedule => unreachable,
            }
        }
    }

    fn runRecoveryLocked(
        self: *Runtime,
        timestamp_ms: i64,
    ) execution.RecoveryError!execution.RecoveryReport {
        std.debug.assert(self.recovery_state.load(.acquire) == .running);
        const report = self.owner.recoverTree(
            self.root_id,
            timestamp_ms,
        ) catch |err| {
            self.requestRetirementSweep(timestamp_ms);
            self.finishRecoveryLocked(.failed);
            return err;
        };
        self.requestRetirementSweep(timestamp_ms);
        self.finishRecoveryLocked(if (report.fullyReconciled())
            .fully_reconciled
        else
            .incomplete);
        return report;
    }

    fn finishRecoveryLocked(self: *Runtime, outcome: RecoveryFinishOutcome) void {
        self.recovery_state.store(recoveryStateAfterFinish(outcome), .release);
        self.recovery_condition.broadcast(io_mod.getIo());
    }

    /// Admits at most one automatic restart reconciliation for this host.
    /// Partial or failed work remains deferred until an explicit operation.
    pub fn requestBackgroundRecovery(
        self: *Runtime,
        timestamp_ms: i64,
    ) BackgroundRecoveryError!void {
        while (true) {
            const state = self.recovery_state.load(.acquire);
            switch (decideRecoveryStart(state, .automatic)) {
                .no_effect => return,
                .schedule => {
                    if (self.recovery_state.cmpxchgStrong(
                        .pending,
                        .scheduled,
                        .acq_rel,
                        .acquire,
                    ) != null) continue;
                    break;
                },
                .start, .wait => unreachable,
            }
        }

        self.recovery_thread = std.Thread.spawn(
            .{},
            backgroundRecoveryMain,
            .{ self, timestamp_ms },
        ) catch {
            const io = io_mod.getIo();
            self.recovery_mutex.lockUncancelable(io);
            self.recovery_state.store(.deferred, .release);
            self.recovery_condition.broadcast(io);
            self.recovery_mutex.unlock(io);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn recoveryState(self: *const Runtime) RecoveryState {
        return self.recovery_state.load(.acquire);
    }

    pub fn requestRetirementSweep(self: *Runtime, timestamp_ms: i64) void {
        if (comptime builtin.single_threaded) return;
        self.owner.requestRetirementSweep(timestamp_ms) catch |err| {
            debug_trace.logf(
                "subagent",
                "retirement sweep wake failed root_id={s} outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
            return;
        };
        debug_trace.logf(
            "subagent",
            "retirement sweep requested root_id={s}",
            .{self.root_id},
        );
    }

    fn backgroundRecoveryMain(self: *Runtime, timestamp_ms: i64) void {
        const io = io_mod.getIo();
        self.recovery_mutex.lockUncancelable(io);
        std.debug.assert(self.recovery_state.load(.acquire) == .scheduled);
        self.recovery_state.store(.running, .release);
        const report = self.runRecoveryLocked(timestamp_ms) catch |err| {
            self.recovery_mutex.unlock(io);
            debug_trace.logf(
                "subagent",
                "background host recovery deferred root_id={s} trigger=automatic state=deferred outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
            return;
        };
        const final_state = self.recovery_state.load(.acquire);
        self.recovery_mutex.unlock(io);
        debug_trace.logf(
            "subagent",
            "background host recovery finished root_id={s} trigger=automatic state={s} changed={d} interrupted={d} completed={d} busy={d} failed={d}",
            .{
                self.root_id,
                @tagName(final_state),
                report.sessions_changed,
                report.work_interrupted,
                report.work_completed,
                report.sessions_external_busy,
                report.sessions_failed,
            },
        );
    }

    /// Typed human/model shared `message.send` path. The invocation identity is
    /// stable across retries; the returned manager result is allocator-owned.
    pub fn sendMessage(
        self: *Runtime,
        alloc: Allocator,
        options: MessageSendOptions,
    ) !manager_mod.Result {
        var command = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
            .id = options.child_id,
            .content = options.content,
        } } });
        defer command.deinit(alloc);
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .human);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .human,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);
        const owned_root_user_intent_context = try buildHumanQueuedRootUserContext(
            alloc,
            command,
        );
        defer if (owned_root_user_intent_context) |context| alloc.free(context);
        const root_user_messages = [_][]const u8{options.content};
        var result = try self.sendMessageWithOperation(
            alloc,
            command,
            operation_id,
            options.caller_id,
            owned_root_user_intent_context orelse "",
            &root_user_messages,
            true,
            options.timestamp_ms,
            .human,
            identity_epoch,
            identity_admitted,
        );
        normalizeRetiredResult(identity_admitted, &result);
        self.finishOperationResult(alloc, operation_id, &result);
        return result;
    }

    fn sendMessageWithOperation(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        operation_id: []const u8,
        caller_id: []const u8,
        root_user_intent_context: []const u8,
        root_user_messages: []const []const u8,
        root_user_evidence_complete: bool,
        timestamp_ms: i64,
        identity_source: domain.OperationIdentitySource,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !manager_mod.Result {
        std.debug.assert(command == .message and command.message == .send);
        const send = command.message.send;
        if (identity_admitted and
            !std.mem.eql(u8, caller_id, self.root_id) and
            !try self.isAttached(self.root_id, caller_id))
        {
            return .{ .failure = .{ .code = .caller_unavailable } };
        }
        if (identity_admitted and !std.mem.eql(u8, send.id, caller_id)) {
            const directly_related =
                try self.isDirectParent(caller_id, send.id) or
                try self.isDirectParent(send.id, caller_id);
            if (!directly_related and !try self.isAttached(caller_id, send.id)) {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
        }
        var context: manager_mod.Context = .{
            .actor_id = caller_id,
            .root_user_intent_context = root_user_intent_context,
            .root_user_messages = root_user_messages,
            .root_user_evidence_complete = root_user_evidence_complete,
            .operation_id = operation_id,
            .operation_identity_source = identity_source,
            .operation_identity_epoch = identity_epoch,
            .operation_identity_admitted = identity_admitted,
            .timestamp_ms = timestamp_ms,
        };
        if (identity_admitted and
            std.mem.eql(u8, caller_id, self.root_id) and
            !std.mem.eql(u8, send.id, caller_id))
        {
            context.target_authorization = .{ .attached_to_root = self.root_id };
        }
        const result = try self.manager.execute(alloc, command, context);
        if (result == .receipt) self.requestStart(result.receipt.target_id, false);
        return result;
    }

    fn executeAuthorizedCommand(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        context: manager_mod.Context,
        defaults: Defaults,
    ) !manager_mod.Result {
        var mutable_context = context;
        if (mutable_context.operation_identity_admitted and
            (command == .configure or command == .lifecycle))
        {
            mutable_context.target_authorization = .{
                .attached_to_root = self.root_id,
            };
        }
        var result = if (command == .create)
            try self.createChild(alloc, command, &mutable_context, defaults)
        else if (command == .lifecycle and command.lifecycle.action == .close)
            if (mutable_context.operation_identity_admitted)
                try self.owner.close(alloc, command.lifecycle.id, mutable_context)
            else
                try self.manager.execute(alloc, command, mutable_context)
        else if (command == .relationship and command.relationship.action == .detach)
            try self.owner.detach(alloc, command.relationship.id, mutable_context)
        else
            try self.manager.execute(alloc, command, mutable_context);
        errdefer result.deinit(alloc);

        if (result == .receipt) switch (command) {
            .create => if (command.create.prompt != null) {
                self.requestStart(result.receipt.target_id, false);
            },
            .message => |message| switch (message) {
                .send => self.requestStart(result.receipt.target_id, false),
                .milestone => {},
            },
            .lifecycle => |lifecycle| switch (lifecycle.action) {
                .cancel => try self.owner.completeCommittedCancellation(
                    lifecycle.id,
                    context.timestamp_ms,
                ),
                .@"resume", .reopen => self.requestStart(
                    lifecycle.id,
                    lifecycle.action == .@"resume",
                ),
                .close => {},
            },
            .relationship => self.requestRetirementSweep(context.timestamp_ms),
            .inspect, .configure => {},
        };
        return result;
    }

    fn recoverIfNeeded(self: *Runtime, timestamp_ms: i64) void {
        _ = self.reconcileAfterRestart(timestamp_ms) catch |err| {
            debug_trace.logf(
                "subagent",
                "lazy host recovery failed root_id={s} outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
        };
    }

    fn requestStart(self: *Runtime, child_id: []const u8, retry_interrupted: bool) void {
        _ = self.owner.start(child_id, retry_interrupted) catch |err| {
            debug_trace.logf(
                "subagent",
                "child wake failed child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
        };
    }

    fn createChild(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        context: *manager_mod.Context,
        defaults: Defaults,
    ) !manager_mod.Result {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        ) catch |err| return mapCreateCapabilityError(err);
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = store.acquireLock() catch |err| return mapCreateLockError(err);
        defer lock.release();
        const existing = store.loadOptional(alloc) catch |err|
            return mapCreateLoadError(err);
        var record = if (existing) |value|
            value
        else
            try create_store.Record.init(alloc, self.root_id);
        defer record.deinit(alloc);

        const operation_id = context.operation_id orelse
            return .{ .failure = .{ .code = .operation_id_required } };
        const request_identity = domain.OperationRequestFingerprintInput{
            .command = command,
            .actor_id = context.actor_id,
            .target_id = "",
            .source_id = null,
            .effective_parent_id = context.actor_id,
        };
        const request_fingerprint = domain.operationRequestFingerprint(
            request_identity,
        );
        const legacy_request_fingerprint =
            domain.legacyImplicitAutoCreateRequestFingerprint(request_identity);
        var child_id: []const u8 = undefined;
        var legacy_implicit_auto = false;
        if (record.find(operation_id)) |entry| {
            const primary_matches = std.mem.eql(
                u8,
                &entry.request_fingerprint,
                &request_fingerprint,
            );
            const legacy_matches = legacy_request_fingerprint != null and
                std.mem.eql(
                    u8,
                    &entry.request_fingerprint,
                    &legacy_request_fingerprint.?,
                );
            if (!primary_matches and !legacy_matches) {
                return .{ .failure = .{ .code = .operation_conflict } };
            }
            legacy_implicit_auto = !primary_matches and legacy_matches;
            child_id = entry.child_id;
        } else if (record.classify(operation_id) == .expired) {
            return .{ .failure = .{ .code = .operation_replay_expired } };
        } else {
            const reserved_id = try session_store.generateSessionId(alloc);
            defer alloc.free(reserved_id);
            try record.append(
                alloc,
                operation_id,
                request_fingerprint,
                reserved_id,
            );
            store.save(alloc, record) catch |err| {
                if (err != error.CommitIndeterminate or
                    !try reservationWasCommitted(
                        alloc,
                        store,
                        operation_id,
                        request_fingerprint,
                        reserved_id,
                    )) return mapCreateSaveError(err);
            };
            child_id = record.find(operation_id).?.child_id;
        }

        var effective_command = command;
        if (legacy_implicit_auto) {
            effective_command.create.configuration.permission_mode = .auto;
        }
        context.created_child_id = child_id;
        var result = try self.manager.execute(alloc, effective_command, context.*);
        if (result != .failure or result.failure.code != .session_not_found) return result;
        result.deinit(alloc);

        var state = try freshChildState(
            alloc,
            child_id,
            self.sessions.workspace_root,
            effective_command.create,
            defaults,
        );
        defer state.deinit(alloc);
        var writable = self.sessions.startWritableSession(alloc, state) catch |err| {
            if (err == error.SessionAlreadyExists) {
                return self.manager.execute(alloc, effective_command, context.*);
            }
            return error.SessionStoreUnavailable;
        };
        result = self.manager.execute(alloc, effective_command, context.*) catch |err| {
            _ = self.sessions.discardPristineStartedSession(alloc, &writable);
            return err;
        };
        if (result == .failure and result.failure.code != .control_commit_indeterminate) {
            _ = self.sessions.discardPristineStartedSession(alloc, &writable);
            return result;
        }
        writable.log.park();
        writable.deinit(alloc);
        return result;
    }

    fn operationIdentityOutstanding(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
    ) !bool {
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse return false;
        defer record.deinit(alloc);
        return record.hasOutstanding(operation_id);
    }

    fn finishModelOutcome(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        outcome: *ModelCommandOutcome,
    ) void {
        const resolution: create_store.IdentityResolution = switch (outcome.*) {
            .result => |result| operationIdentityResolution(result),
            .relationship_approval => .pending_approval,
            .adapter_failure => |failure| if (failure.retryable)
                .retryable_failure
            else
                .stable_failure,
        };
        if (create_store.identityFinalization(resolution) == .retain) return;
        self.finalizeOperationIdentity(
            operation_id,
            .retire,
        ) catch {
            outcome.deinit(alloc);
            outcome.* = .{ .result = .{ .failure = .{
                .code = .control_commit_indeterminate,
                .retryable = true,
            } } };
        };
    }

    fn finishOperationResult(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        result: *manager_mod.Result,
    ) void {
        const finalization = create_store.identityFinalization(
            operationIdentityResolution(result.*),
        );
        if (finalization == .retain) return;
        self.finalizeOperationIdentity(operation_id, finalization) catch {
            result.deinit(alloc);
            result.* = .{ .failure = .{
                .code = .control_commit_indeterminate,
                .retryable = true,
            } };
        };
    }

    pub fn abortOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
        identity_epoch: u64,
    ) !void {
        if (identity_epoch == 0) return;
        const operation_id = try tool_result.boundOperationIdAlloc(
            self.alloc,
            invocation_id,
            source,
            identity_epoch,
        );
        defer self.alloc.free(operation_id);
        try self.finalizeOperationIdentity(operation_id, .retire);
    }

    fn completeOperationIdentity(
        self: *Runtime,
        operation_id: []const u8,
    ) !void {
        return self.finalizeOperationIdentity(operation_id, .retire);
    }

    fn finalizeOperationIdentity(
        self: *Runtime,
        operation_id: []const u8,
        finalization: create_store.IdentityFinalization,
    ) !void {
        const alloc = self.alloc;
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse return;
        defer record.deinit(alloc);
        if (!try record.finalizeIdentity(
            alloc,
            operation_id,
            finalization,
        )) return;
        store.save(alloc, record) catch |err| {
            if (err != error.CommitIndeterminate or
                !try outstandingIdentityCompletionWasCommitted(
                    alloc,
                    store,
                    operation_id,
                ))
            {
                return err;
            }
        };
    }

    fn encodeResult(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        result: manager_mod.Result,
        max_result_bytes: usize,
        status_override: ?[]const u8,
    ) ![]u8 {
        _ = self;
        var requested: std.Io.Writer.Allocating = .init(alloc);
        defer requested.deinit();
        var child_id: ?[]const u8 = null;
        var status: []const u8 = "accepted";
        var error_code: ?[]const u8 = null;
        var retryable = false;
        var cursor: ?[]const u8 = null;
        switch (result) {
            .receipt => |receipt| {
                child_id = receipt.target_id;
                status = @tagName(receipt.code);
                try requested.writer.print(
                    "{{\"outcome\":\"{s}\",\"generation\":{d},\"event_sequence\":{d}}}",
                    .{ @tagName(receipt.code), receipt.generation, receipt.event_sequence },
                );
            },
            .inspection => |inspection| {
                child_id = inspection.child_id;
                status = status_override orelse
                    if (inspection.status) |state| @tagName(state) else "inspected";
                cursor = inspection.next_cursor;
                try std.json.Stringify.value(inspection, .{}, &requested.writer);
            },
            .failure => |failure| {
                error_code = @tagName(failure.code);
                retryable = failure.retryable;
                status = "rejected";
                try requested.writer.writeAll("null");
            },
        }
        const requested_json = requested.writer.buffered();
        var encoded = try tool_result.outcomeAlloc(alloc, .{
            .ok = result != .failure,
            .operation_id = operation_id,
            .child_id = child_id,
            .status = status,
            .error_code = error_code,
            .retryable = retryable,
            .requested_json = requested_json,
            .cursor = cursor,
        });
        if (encoded.len <= max_result_bytes) return encoded;
        alloc.free(encoded);
        encoded = try tool_result.failureAlloc(
            alloc,
            operation_id,
            child_id,
            "rejected",
            "result_too_large",
            true,
            cursor,
        );
        return encoded;
    }

    fn isAttached(self: *Runtime, root_id: []const u8, candidate: []const u8) !bool {
        var result = try self.manager.snapshot(self.alloc, .{
            .root_id = root_id,
            .anchor_id = candidate,
            .limit = 1,
        });
        defer result.deinit(self.alloc);
        return switch (result) {
            .failure => false,
            .snapshot => |snapshot| snapshot.nodes.len == 1 and
                std.mem.eql(u8, snapshot.nodes[0].child_id, candidate),
        };
    }

    fn isDirectParent(
        self: *Runtime,
        child_id: []const u8,
        candidate_parent_id: []const u8,
    ) !bool {
        return self.manager.isDirectParent(
            self.alloc,
            child_id,
            candidate_parent_id,
        );
    }
};

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(self: ModePolicy, tool_set: tool_set_contract.ToolSet, tool_name: []const u8) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(tool_set, active.id, tool_name),
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

test "host authority capture applies explicit mode and permission capability policy" {
    const Fixture = struct {
        fn decode(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
            return .{ .failure = try ctx.allocator.dupe(u8, "unused") };
        }

        fn call(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            return .{ .failure = try ctx.allocator.dupe(u8, "unused") };
        }

        fn readsOnly(_: tool_dispatch.ToolInput) bool {
            return true;
        }

        fn irreversible(_: tool_dispatch.ToolInput) bool {
            return false;
        }

        const seed = tool_dispatch.Tool{
            .name = "inspect",
            .description = "Inspect",
            .gateway_schema = .{
                .name = "inspect",
                .description = "Inspect",
                .input_schema = .{},
            },
            .decode = decode,
            .call = call,
            .reads_only_fn = readsOnly,
            .irreversible_fn = irreversible,
        };

        const tools = [_]tool_dispatch.Tool{
            seed,
            renamed(seed, "list_files"),
            renamed(seed, "mutate"),
        };

        fn renamed(tool: tool_dispatch.Tool, name: []const u8) tool_dispatch.Tool {
            var result = tool;
            result.name = name;
            result.gateway_schema.name = name;
            return result;
        }
    };
    const modes = [_]mode_registry.ModeSpec{
        .{ .id = "full", .name = "Full" },
        .{ .id = "inspect", .name = "Inspect", .tool_policy = .read_only },
    };
    const tool_set = tool_set_contract.ToolSet{
        .registry = .{ .tools = Fixture.tools[0..] },
        .order = &.{ "inspect", "list_files", "mutate" },
        .read_only_tool_names = &.{ "inspect", "list_files" },
    };
    const registry = mode_registry.Registry{
        .default_mode_id = "full",
        .modes = modes[0..],
    };

    var full = try captureHostAuthority(
        std.testing.allocator,
        .{ .tool_set = tool_set, .mode = .full },
        &.{},
        .{},
        &.{},
    );
    defer full.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), full.tools.len);
    try std.testing.expectEqualStrings("inspect", full.tools[0]);
    try std.testing.expectEqualStrings("list_files", full.tools[1]);
    try std.testing.expectEqualStrings("mutate", full.tools[2]);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("list"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("inspect"),
        .target_path = @constCast("workspace"),
    }};
    var restricted = try captureHostAuthority(
        std.testing.allocator,
        .{
            .tool_set = tool_set,
            .mode = .{ .active = .{ .registry = registry, .id = "inspect" } },
        },
        &.{"mcp__example"},
        .{ .rules = rules[0..] },
        grants[0..],
    );
    defer restricted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), restricted.tools.len);
    try std.testing.expectEqualStrings("inspect", restricted.tools[0]);
    try std.testing.expectEqualStrings("mcp__example", restricted.integrations[0]);
    try std.testing.expectEqualStrings("list", restricted.rules.rules[0].permission);
    try std.testing.expectEqualStrings("inspect", restricted.grants[0].tool_name);
}

fn commandTarget(command: domain.Command) ?[]const u8 {
    return switch (command) {
        .create => null,
        .message => |message| switch (message) {
            .send => |send| send.id,
            .milestone => null,
        },
        .inspect => |value| value.id,
        .relationship => |value| value.id,
        .configure => |value| value.id,
        .lifecycle => |value| value.id,
    };
}

fn relationshipContinuationLoadRetryable(
    err: approval_persistence.Error,
) bool {
    return switch (err) {
        error.OutOfMemory,
        error.LockBusy,
        error.StoreUnavailable,
        error.CommitIndeterminate,
        => true,
        error.ChildNotAttached,
        error.RelationshipCycle,
        error.GraphTooDeep,
        error.InvalidRequest,
        error.RequestConflict,
        error.RequestResolved,
        error.LockUnsupported,
        error.CapacityExceeded,
        => false,
    };
}

fn operationIdentityResolution(
    result: manager_mod.Result,
) create_store.IdentityResolution {
    return switch (result) {
        .receipt => .receipt,
        .inspection => .stable_failure,
        .failure => |failure| if (failure.code == .control_commit_indeterminate)
            .commit_indeterminate
        else if (failure.retryable)
            .retryable_failure
        else
            .stable_failure,
    };
}

fn normalizeRetiredResult(
    identity_admitted: bool,
    result: *manager_mod.Result,
) void {
    if (identity_admitted or result.* != .failure or result.failure.retryable) {
        return;
    }
    if (result.failure.code == .operation_conflict or
        result.failure.code == .operation_replay_expired)
    {
        return;
    }
    result.* = .{ .failure = .{ .code = .operation_replay_expired } };
}

fn relationshipApprovalLabel(action: domain.RelationshipAction) []const u8 {
    return switch (action) {
        .attach => "Attach existing subagent",
        .reparent => "Reparent subagent",
        .detach => unreachable,
    };
}

fn encodeRelationshipApprovalIntent(
    alloc: Allocator,
    operation_id: []const u8,
    relationship: domain.RelationshipCommand,
    max_result_bytes: usize,
) ![]u8 {
    var requested: std.Io.Writer.Allocating = .init(alloc);
    defer requested.deinit();
    try requested.writer.writeAll("{\"action\":");
    try std.json.Stringify.value(@tagName(relationship.action), .{}, &requested.writer);
    try requested.writer.writeAll(",\"approval_id\":");
    try std.json.Stringify.value(operation_id, .{}, &requested.writer);
    try requested.writer.writeByte('}');

    const encoded = try tool_result.outcomeAlloc(alloc, .{
        .ok = true,
        .operation_id = operation_id,
        .child_id = relationship.id,
        .status = "awaiting_approval",
        .error_code = null,
        .retryable = false,
        .requested_json = requested.writer.buffered(),
        .cursor = null,
    });
    if (encoded.len <= max_result_bytes) return encoded;
    alloc.free(encoded);
    return boundedFailureAlloc(
        alloc,
        operation_id,
        relationship.id,
        "result_too_large",
        false,
        max_result_bytes,
    );
}

fn boundedFailureAlloc(
    alloc: Allocator,
    operation_id: []const u8,
    child_id: ?[]const u8,
    error_code: []const u8,
    retryable: bool,
    max_result_bytes: usize,
) ![]u8 {
    const encoded = try tool_result.failureAlloc(
        alloc,
        operation_id,
        child_id,
        "rejected",
        error_code,
        retryable,
        null,
    );
    if (encoded.len <= max_result_bytes) return encoded;
    alloc.free(encoded);
    return tool_result.failureAlloc(
        alloc,
        operation_id,
        null,
        "rejected",
        "result_too_large",
        retryable,
        null,
    );
}

fn applyCreateDefaults(
    alloc: Allocator,
    create: *domain.CreateCommand,
    defaults: Defaults,
) !void {
    if (create.configuration.model == null) {
        create.configuration.model = try alloc.dupe(u8, defaults.model);
    }
    if (create.configuration.effort == null) create.configuration.effort = defaults.effort;
}

fn freshChildState(
    alloc: Allocator,
    child_id: []const u8,
    workspace_root: []const u8,
    create: domain.CreateCommand,
    defaults: Defaults,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try alloc.dupe(u8, child_id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, create.configuration.model orelse defaults.model);
    errdefer alloc.free(model);
    const history = try alloc.alloc(types.HistoryTurn, 0);
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
            .effort = create.configuration.effort orelse defaults.effort,
            .fast_mode = defaults.fast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "fresh child state persists its provider with the model" {
    const alloc = std.testing.allocator;
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "codex-child",
        .mode = .persistent,
    } });
    defer command.deinit(alloc);
    var state = try freshChildState(
        alloc,
        "01J00000000000000000000000",
        "/tmp/workspace",
        command.create,
        .{
            .provider = .codex,
            .model = "gpt-5.6-sol",
            .effort = types.ReasoningEffort.literal("high"),
            .conversation_language = session.ConversationLanguage.literal("en"),
        },
    );
    defer state.deinit(alloc);

    try std.testing.expectEqual(model_provider.ProviderId.codex, state.preferences.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", state.preferences.model);
}

fn reservationWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    child_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return false;
    defer observed.deinit(alloc);
    const entry = observed.find(operation_id) orelse return false;
    return std.mem.eql(u8, &entry.request_fingerprint, &request_fingerprint) and
        std.mem.eql(u8, entry.child_id, child_id);
}

fn issueManagerOperationIdentity(
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []const u8,
    child_store_options: session_child_store.Options,
    invocation_id: []const u8,
    source: domain.OperationIdentitySource,
) !u64 {
    var capability = try sessions.openSubagentControlCapabilityWritable(
        alloc,
        root_id,
        child_store_options,
    );
    defer capability.deinit();
    const store = create_store.Store{
        .capability = &capability,
        .expected_root_id = root_id,
    };
    var lock = try store.acquireLock();
    defer lock.release();
    const existing = try store.loadOptional(alloc);
    var record = if (existing) |value|
        value
    else
        try create_store.Record.init(alloc, root_id);
    defer record.deinit(alloc);
    if (record.outstandingEpochForInvocation(invocation_id, source)) |epoch| {
        return epoch;
    }
    const epoch = try record.reserveIdentity(alloc, invocation_id, source);
    const operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        source,
        epoch,
    );
    defer alloc.free(operation_id);
    store.save(alloc, record) catch |err| {
        if (err != error.CommitIndeterminate or
            !try outstandingIdentityWasCommitted(
                alloc,
                store,
                operation_id,
            ))
        {
            return err;
        }
    };
    return epoch;
}

fn outstandingIdentityWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return false;
    defer observed.deinit(alloc);
    return observed.hasOutstanding(operation_id);
}

fn outstandingIdentityCompletionWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return true;
    defer observed.deinit(alloc);
    return !observed.hasOutstanding(operation_id);
}

fn mapCreateCapabilityError(err: session_store.OpenSubagentControlError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.InvalidSessionId, error.SessionNotFound => .session_not_found,
        error.SessionPathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.OutOfMemory, error.SessionStoreUnavailable, error.SessionChildStoreFailed => .store_failure,
    } } };
}

fn mapCreateLockError(err: create_store.LockError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.LockBusy => .control_lock_busy,
        error.LockUnsupported => .control_lock_unsupported,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.OutOfMemory, error.StoreFailed => .store_failure,
    }, .retryable = err == error.LockBusy } };
}

fn mapCreateLoadError(err: create_store.LoadError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.InvalidRecord, error.UnsupportedSchema => .control_record_invalid,
        error.RecordTooLarge => .control_record_too_large,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.RecordNotFound, error.OutOfMemory, error.StoreFailed => .store_failure,
    } } };
}

fn mapCreateSaveError(err: create_store.SaveError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.RecordTooLarge => .control_record_too_large,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.CommitIndeterminate => .control_commit_indeterminate,
        error.IdentityMismatch => .control_record_invalid,
        error.OutOfMemory, error.StoreFailed => .store_failure,
    }, .retryable = err == error.CommitIndeterminate } };
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

fn testState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    const model = try alloc.dupe(u8, "test/model");
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{ .model = model, .effort = types.ReasoningEffort.literal("high"), .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const TestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !TestEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *TestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        var state = try testState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }
};

const AlwaysBusyControlLock = struct {
    now_ms: i64 = 0,

    fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(raw: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.now_ms;
    }

    fn sleep(raw: ?*anyopaque, millis: u64) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.now_ms += @intCast(millis);
    }

    fn options(self: *@This()) session_child_store.Options {
        return .{ .lock_ops = .{
            .ctx = self,
            .try_lock = tryLock,
            .now_ms = now,
            .sleep_ms = sleep,
        } };
    }
};

fn readIdentityProcessFd(fd: std.c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(read_count)) {
            .SUCCESS => {
                if (read_count == 0) return error.ProcessPipeFailed;
                offset += @intCast(read_count);
            },
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn writeIdentityProcessFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const write_count = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(write_count)) {
            .SUCCESS => offset += @intCast(write_count),
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn closeIdentityProcessFd(fd: std.c.fd_t) void {
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    file.close(io_mod.getIo());
}

fn waitIdentityProcess(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(waited)) {
            .SUCCESS => {
                if (waited != pid or (status & 0x7f) != 0) {
                    return error.ProcessWaitFailed;
                }
                return @intCast((status >> 8) & 0xff);
            },
            .INTR => continue,
            else => return error.ProcessWaitFailed,
        }
    }
}

fn forkIdentityIssuer(
    home: []const u8,
    workspace: []const u8,
    root_id: []const u8,
    invocation_id: []const u8,
    marker: u64,
    ready_fd: std.c.fd_t,
    start_fd: std.c.fd_t,
    result_fd: std.c.fd_t,
) !std.c.pid_t {
    const pid = std.c.fork();
    if (pid < 0) return error.ProcessForkFailed;
    if (pid != 0) return pid;

    writeIdentityProcessFd(ready_fd, &.{1}) catch std.c._exit(100);
    var start: [1]u8 = undefined;
    readIdentityProcessFd(start_fd, &start) catch std.c._exit(101);
    const alloc = std.heap.c_allocator;
    var sessions = session_store.Store.initFromHome(
        alloc,
        home,
        workspace,
    ) catch std.c._exit(102);
    const epoch = issueManagerOperationIdentity(
        alloc,
        &sessions,
        root_id,
        .{},
        invocation_id,
        .model,
    ) catch std.c._exit(103);
    const result = [2]u64{ marker, epoch };
    writeIdentityProcessFd(result_fd, std.mem.asBytes(&result)) catch
        std.c._exit(104);
    sessions.deinit(alloc);
    std.c._exit(0);
}

test "independent processes receive distinct authoritative operation identities" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);

    var ready_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.ProcessPipeFailed;
    defer closeIdentityProcessFd(ready_pipe[0]);
    defer closeIdentityProcessFd(ready_pipe[1]);
    var start_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&start_pipe) != 0) return error.ProcessPipeFailed;
    defer closeIdentityProcessFd(start_pipe[0]);
    defer closeIdentityProcessFd(start_pipe[1]);
    var result_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&result_pipe) != 0) return error.ProcessPipeFailed;
    defer closeIdentityProcessFd(result_pipe[0]);
    defer closeIdentityProcessFd(result_pipe[1]);

    const first_pid = try forkIdentityIssuer(
        env.home,
        env.workspace,
        root_id,
        "process-identity-a",
        1,
        ready_pipe[1],
        start_pipe[0],
        result_pipe[1],
    );
    const second_pid = forkIdentityIssuer(
        env.home,
        env.workspace,
        root_id,
        "process-identity-b",
        2,
        ready_pipe[1],
        start_pipe[0],
        result_pipe[1],
    ) catch |err| {
        writeIdentityProcessFd(start_pipe[1], &.{1}) catch {};
        _ = waitIdentityProcess(first_pid) catch {};
        return err;
    };
    var ready: [2]u8 = undefined;
    try readIdentityProcessFd(ready_pipe[0], &ready);
    try writeIdentityProcessFd(start_pipe[1], &.{ 1, 1 });
    var results: [4]u64 = undefined;
    try readIdentityProcessFd(result_pipe[0], std.mem.asBytes(&results));
    try std.testing.expectEqual(@as(u8, 0), try waitIdentityProcess(first_pid));
    try std.testing.expectEqual(@as(u8, 0), try waitIdentityProcess(second_pid));

    var first_epoch: ?u64 = null;
    var second_epoch: ?u64 = null;
    for (0..2) |index| {
        const marker = results[index * 2];
        const epoch = results[index * 2 + 1];
        if (marker == 1) {
            first_epoch = epoch;
        } else if (marker == 2) {
            second_epoch = epoch;
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(first_epoch != null and second_epoch != null);
    try std.testing.expect(first_epoch.? != second_epoch.?);
    try std.testing.expect(
        (first_epoch.? == 1 and second_epoch.? == 2) or
            (first_epoch.? == 2 and second_epoch.? == 1),
    );

    const first_retry = try issueManagerOperationIdentity(
        alloc,
        &env.store,
        root_id,
        .{},
        "process-identity-a",
        .model,
    );
    const second_retry = try issueManagerOperationIdentity(
        alloc,
        &env.store,
        root_id,
        .{},
        "process-identity-b",
        .model,
    );
    try std.testing.expectEqual(first_epoch.?, first_retry);
    try std.testing.expectEqual(second_epoch.?, second_retry);
}

const TestAuthority = struct {
    root_id: []const u8,
    tools: []const []const u8 = &.{"subagent"},
    integrations: []const []const u8 = &.{},
    rules: types.PermissionRuleSet = .{},
    grants: []const types.PermissionGrant = &.{},

    fn resolver(self: *TestAuthority) authority.HostResolver {
        return .{ .context = self, .resolve_fn = resolve };
    }

    fn resolve(
        raw: ?*anyopaque,
        alloc: Allocator,
        root_id: []const u8,
    ) authority.HostResolveError!authority.HostAuthority {
        const self: *TestAuthority = @ptrCast(@alignCast(raw.?));
        if (!std.mem.eql(u8, self.root_id, root_id)) {
            return error.HostAuthorityUnavailable;
        }
        return authority.HostAuthority.capture(
            alloc,
            self.tools,
            self.integrations,
            self.rules,
            self.grants,
        );
    }
};

fn forceDurableReplayHorizon(
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []const u8,
    child_id: []const u8,
    horizon: u64,
) !void {
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        record.identity_epoch_high = horizon;
        record.legacy_replay_closed = true;
        record.model_replay_floor = horizon;
        record.human_replay_floor = horizon;
        record.model_epoch_high = horizon;
        record.human_epoch_high = horizon;
        try store.save(alloc, record);
    }
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        record.legacy_replay_closed = true;
        record.model_replay_floor = horizon;
        record.human_replay_floor = horizon;
        record.model_epoch_high = horizon;
        record.human_epoch_high = horizon;
        try store.save(alloc, record);
    }
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var ledger = if (try store.loadOptional(alloc)) |existing|
            existing
        else
            try communication.Ledger.init(alloc, child_id);
        defer ledger.deinit(alloc);
        ledger.legacy_operation_replay_closed = true;
        ledger.model_replay_floor = horizon;
        ledger.human_replay_floor = horizon;
        ledger.model_epoch_high = horizon;
        ledger.human_epoch_high = horizon;
        try store.save(alloc, ledger);
    }
}

test "older runtime and lower-clock restart cross the durable replay horizon" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const older_host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer older_host.deinit();
    const newer_host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer newer_host.deinit();

    var initial_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "horizon-target",
        .mode = .persistent,
    } });
    defer initial_create.deinit(alloc);
    var initial_options = testOptions(root_id, "newer-before-horizon");
    initial_options.timestamp_ms = 10_000;
    const initial_result = try newer_host.execute(
        alloc,
        &initial_create,
        initial_options,
    );
    defer alloc.free(initial_result);
    const child_id = try resultChildIdAlloc(alloc, initial_result);
    defer alloc.free(child_id);
    try forceDurableReplayHorizon(
        alloc,
        &env.store,
        root_id,
        child_id,
        50,
    );

    var older_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "older-runtime-create",
        .mode = .persistent,
    } });
    defer older_create.deinit(alloc);
    var older_create_options = testOptions(root_id, "older-runtime-create");
    older_create_options.timestamp_ms = -300;
    older_create_options.identity_epoch = try older_host.issueOperationIdentity(
        alloc,
        older_create_options.invocation_id,
        .model,
    );
    try std.testing.expectEqual(@as(u64, 51), older_create_options.identity_epoch);
    try std.testing.expectEqual(
        older_create_options.identity_epoch,
        try older_host.issueOperationIdentity(
            alloc,
            older_create_options.invocation_id,
            .model,
        ),
    );
    const older_created = try older_host.execute(
        alloc,
        &older_create,
        older_create_options,
    );
    defer alloc.free(older_created);
    try std.testing.expect(std.mem.find(u8, older_created, "\"ok\":true") != null);

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "older-runtime-configured",
    } });
    defer configure.deinit(alloc);
    var configure_options = testOptions(root_id, "older-runtime-configure");
    configure_options.timestamp_ms = -250;
    configure_options.identity_epoch = try older_host.issueOperationIdentity(
        alloc,
        configure_options.invocation_id,
        .model,
    );
    try std.testing.expectEqual(@as(u64, 52), configure_options.identity_epoch);
    const configured = try older_host.execute(
        alloc,
        &configure,
        configure_options,
    );
    defer alloc.free(configured);
    try std.testing.expect(std.mem.find(u8, configured, "\"ok\":true") != null);

    const restarted_host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer restarted_host.deinit();
    var restarted_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "lower-clock-model",
        .mode = .persistent,
    } });
    defer restarted_create.deinit(alloc);
    var restarted_create_options = testOptions(root_id, "restart-model");
    restarted_create_options.timestamp_ms = -500;
    restarted_create_options.identity_epoch = try restarted_host.issueOperationIdentity(
        alloc,
        restarted_create_options.invocation_id,
        .model,
    );
    try std.testing.expectEqual(@as(u64, 53), restarted_create_options.identity_epoch);
    const restarted_created = try restarted_host.execute(
        alloc,
        &restarted_create,
        restarted_create_options,
    );
    defer alloc.free(restarted_created);
    try std.testing.expect(std.mem.find(u8, restarted_created, "\"ok\":true") != null);

    var human_configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "lower-clock-human",
    } });
    defer human_configure.deinit(alloc);
    var human_options = testHumanOptions("restart-human");
    human_options.timestamp_ms = -600;
    human_options.identity_epoch = try restarted_host.issueOperationIdentity(
        alloc,
        human_options.invocation_id,
        .human,
    );
    try std.testing.expectEqual(@as(u64, 54), human_options.identity_epoch);
    var human_result = try restarted_host.executeHumanCommand(
        alloc,
        &human_configure,
        human_options,
    );
    defer human_result.deinit(alloc);
    try std.testing.expect(human_result == .receipt);

    var send_options = MessageSendOptions{
        .caller_id = root_id,
        .invocation_id = "older-runtime-delivery",
        .child_id = child_id,
        .content = "cross-horizon delivery",
        .timestamp_ms = -700,
    };
    send_options.identity_epoch = try older_host.issueOperationIdentity(
        alloc,
        send_options.invocation_id,
        .human,
    );
    try std.testing.expectEqual(@as(u64, 55), send_options.identity_epoch);
    var sent = try older_host.sendMessage(alloc, send_options);
    defer sent.deinit(alloc);
    try std.testing.expect(sent == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, sent.receipt.code);
}

fn testOptions(caller_id: []const u8, invocation_id: []const u8) ExecuteOptions {
    return .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .defaults = .{
            .provider = .gateway,
            .model = "test/model",
            .effort = types.ReasoningEffort.literal("high"),
            .conversation_language = session.ConversationLanguage.literal("en"),
        },
        .max_result_bytes = 64 * 1024,
        .timestamp_ms = 10,
    };
}

fn testHumanOptions(invocation_id: []const u8) HumanCommandOptions {
    return .{
        .invocation_id = invocation_id,
        .defaults = .{
            .provider = .gateway,
            .model = "test/model",
            .effort = types.ReasoningEffort.literal("high"),
            .conversation_language = session.ConversationLanguage.literal("en"),
        },
        .timestamp_ms = 10,
    };
}

test "one off caller cannot create before identity or child allocation" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    const caller_id = "01J00000000000000000000001";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    try env.createSession(alloc, caller_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var caller_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "temporary caller",
        .mode = .one_off,
        .prompt = "temporary work",
    } });
    defer caller_create.deinit(alloc);
    var caller_created = try host.manager.execute(alloc, caller_create, .{
        .actor_id = root_id,
        .operation_id = "create-one-off-caller",
        .created_child_id = caller_id,
        .timestamp_ms = 1,
    });
    defer caller_created.deinit(alloc);
    try std.testing.expect(caller_created == .receipt);

    var nested_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "must not exist",
        .mode = .persistent,
    } });
    defer nested_create.deinit(alloc);
    const rejected = try host.execute(
        alloc,
        &nested_create,
        testOptions(caller_id, "one-off-nested-create"),
    );
    defer alloc.free(rejected);
    try std.testing.expect(std.mem.find(u8, rejected, "invalid_state") != null);

    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer root_capability.deinit();
    const operations = create_store.Store{
        .capability = &root_capability,
        .expected_root_id = root_id,
    };
    try std.testing.expect((try operations.loadOptional(alloc)) == null);

    var nested = try host.manager.snapshot(alloc, .{
        .root_id = caller_id,
    });
    defer nested.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), nested.snapshot.nodes.len);
}

test "model child permissions inherit and reject elevation before persistence" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    const RejectedCreate = struct {
        parent: types.PermissionMode,
        child: types.PermissionMode,
        invocation_id: []const u8,
    };
    for ([_]RejectedCreate{
        .{ .parent = .ask, .child = .auto, .invocation_id = "reject-ask-auto" },
        .{ .parent = .ask, .child = .yolo, .invocation_id = "reject-ask-yolo" },
        .{ .parent = .auto, .child = .yolo, .invocation_id = "reject-auto-yolo" },
    }) |case| {
        var command = try domain.validateCommand(alloc, .{ .create = .{
            .name = "rejected-elevation",
            .mode = .persistent,
            .permission_mode = case.child,
        } });
        defer command.deinit(alloc);
        var options = testOptions(root_id, case.invocation_id);
        options.parent_permission_mode = case.parent;
        const rejected = try host.execute(alloc, &command, options);
        defer alloc.free(rejected);
        try std.testing.expect(std.mem.find(u8, rejected, "permission_escalation") != null);
    }

    var initial_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (initial_ids.items) |id| alloc.free(id);
        initial_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), initial_ids.items.len);
    {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        try std.testing.expect((try store.loadOptional(alloc)) == null);
    }

    for ([_]types.PermissionMode{ .ask, .auto, .yolo }, 0..) |parent_mode, index| {
        const invocation_id = try std.fmt.allocPrint(alloc, "inherit-{d}", .{index});
        defer alloc.free(invocation_id);
        const name = try std.fmt.allocPrint(alloc, "inherited-{d}", .{index});
        defer alloc.free(name);
        var command = try domain.validateCommand(alloc, .{ .create = .{
            .name = name,
            .mode = .persistent,
        } });
        defer command.deinit(alloc);
        var options = testOptions(root_id, invocation_id);
        options.parent_permission_mode = parent_mode;
        const encoded = try host.execute(alloc, &command, options);
        defer alloc.free(encoded);
        const child_id = try resultChildIdAlloc(alloc, encoded);
        defer alloc.free(child_id);
        var snapshot = try host.authority_resolver.resolve(alloc, child_id);
        defer snapshot.deinit(alloc);
        try std.testing.expectEqual(parent_mode, snapshot.permission_mode);
    }

    var restrictive = try domain.validateCommand(alloc, .{ .create = .{
        .name = "restrictive-child",
        .mode = .persistent,
        .permission_mode = .ask,
    } });
    defer restrictive.deinit(alloc);
    var restrictive_options = testOptions(root_id, "allow-yolo-ask");
    restrictive_options.parent_permission_mode = .yolo;
    const restrictive_result = try host.execute(
        alloc,
        &restrictive,
        restrictive_options,
    );
    defer alloc.free(restrictive_result);
    try std.testing.expect(std.mem.find(u8, restrictive_result, "\"ok\":true") != null);

    var equal_yolo = try domain.validateCommand(alloc, .{ .create = .{
        .name = "equal-yolo-child",
        .mode = .persistent,
        .permission_mode = .yolo,
    } });
    defer equal_yolo.deinit(alloc);
    const equal_yolo_result = try host.execute(
        alloc,
        &equal_yolo,
        testOptions(root_id, "allow-yolo-yolo"),
    );
    defer alloc.free(equal_yolo_result);
    try std.testing.expect(std.mem.find(u8, equal_yolo_result, "\"ok\":true") != null);
}

test "model configure cannot exceed caller while human manager remains unchanged" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var human_create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "human-default",
        .mode = .persistent,
    } });
    defer human_create.deinit(alloc);
    var human_created = try host.executeHumanCommand(
        alloc,
        &human_create,
        testHumanOptions("human-default-create"),
    );
    defer human_created.deinit(alloc);
    try std.testing.expect(human_created == .receipt);
    const child_id = try alloc.dupe(u8, human_created.receipt.target_id);
    defer alloc.free(child_id);
    var before = try host.authority_resolver.resolve(alloc, child_id);
    defer before.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.yolo, before.permission_mode);

    const RejectedConfigure = struct {
        parent: types.PermissionMode,
        child: types.PermissionMode,
        invocation_id: []const u8,
    };
    for ([_]RejectedConfigure{
        .{ .parent = .ask, .child = .auto, .invocation_id = "reject-configure-ask-auto" },
        .{ .parent = .ask, .child = .yolo, .invocation_id = "reject-configure-ask-yolo" },
        .{ .parent = .auto, .child = .yolo, .invocation_id = "reject-configure-auto-yolo" },
    }) |case| {
        var command = try domain.validateCommand(alloc, .{ .configure = .{
            .id = child_id,
            .permission_mode = case.child,
        } });
        defer command.deinit(alloc);
        var options = testOptions(root_id, case.invocation_id);
        options.parent_permission_mode = case.parent;
        const rejected = try host.execute(alloc, &command, options);
        defer alloc.free(rejected);
        try std.testing.expect(std.mem.find(u8, rejected, "permission_escalation") != null);
    }
    var unchanged = try host.authority_resolver.resolve(alloc, child_id);
    defer unchanged.deinit(alloc);
    try std.testing.expectEqual(before.generation, unchanged.generation);
    try std.testing.expectEqual(types.PermissionMode.yolo, unchanged.permission_mode);

    var lower = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .permission_mode = .ask,
    } });
    defer lower.deinit(alloc);
    const lowered = try host.execute(
        alloc,
        &lower,
        testOptions(root_id, "allow-configure-ask"),
    );
    defer alloc.free(lowered);
    try std.testing.expect(std.mem.find(u8, lowered, "\"ok\":true") != null);
    var current = try host.authority_resolver.resolve(alloc, child_id);
    defer current.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, current.permission_mode);
}

const AuthorizationRaceIds = struct {
    const root = "01J00000000000000000000000";
    const actor = "01J00000000000000000000001";
    const replacement = "01J00000000000000000000002";
    const target = "01J00000000000000000000003";
};

const TargetAuthorizationBarrier = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn pause(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn hook(self: *@This()) TargetAuthorizationTestHook {
        return .{
            .context = self,
            .run_fn = pause,
        };
    }

    fn waitUntilEntered(self: *@This()) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (!self.entered.load(.seq_cst) and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (!self.entered.load(.seq_cst)) return error.TestUnexpectedResult;
    }
};

fn createAuthorizationRaceChild(
    alloc: Allocator,
    manager: *manager_mod.Manager,
    actor_id: []const u8,
    child_id: []const u8,
    operation_id: []const u8,
    name: []const u8,
) !void {
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var result = try manager.execute(alloc, create, .{
        .actor_id = actor_id,
        .operation_id = operation_id,
        .created_child_id = child_id,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.created, result.receipt.code);
}

fn createAuthorizationRaceTree(
    alloc: Allocator,
    env: *TestEnvironment,
    manager: *manager_mod.Manager,
) !void {
    for ([_][]const u8{
        AuthorizationRaceIds.actor,
        AuthorizationRaceIds.replacement,
        AuthorizationRaceIds.target,
    }) |session_id| {
        try env.createSession(alloc, session_id);
    }
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.root,
        AuthorizationRaceIds.actor,
        "create-authorization-actor",
        "stale caller",
    );
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.root,
        AuthorizationRaceIds.replacement,
        "create-authorization-replacement",
        "replacement parent",
    );
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.actor,
        AuthorizationRaceIds.target,
        "create-authorization-target",
        "private target configuration",
    );
}

const PausedInspect = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var inspect = domain.validateCommand(alloc, .{ .inspect = .{
            .id = AuthorizationRaceIds.target,
            .sections = &.{.configuration},
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer inspect.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &inspect,
            testOptions(AuthorizationRaceIds.actor, "stale-inspect"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const PausedConfigure = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var configure = domain.validateCommand(alloc, .{ .configure = .{
            .id = AuthorizationRaceIds.target,
            .name = "unauthorized replacement",
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer configure.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &configure,
            testOptions(AuthorizationRaceIds.actor, "stale-configure"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const PausedPermissionConfigure = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var configure = domain.validateCommand(alloc, .{ .configure = .{
            .id = AuthorizationRaceIds.target,
            .permission_mode = .yolo,
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer configure.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &configure,
            testOptions(AuthorizationRaceIds.actor, "stale-permission-configure"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "inspect revalidates target ancestry after a stale attachment snapshot" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, AuthorizationRaceIds.root);
    var test_authority = TestAuthority{ .root_id = AuthorizationRaceIds.root };
    var host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        AuthorizationRaceIds.root,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    try createAuthorizationRaceTree(alloc, &env, &host.manager);

    var barrier = TargetAuthorizationBarrier{};
    TestHooks.after_target_authorization = barrier.hook();
    var thread: ?std.Thread = null;
    var joined = false;
    defer {
        barrier.release.store(true, .seq_cst);
        if (thread) |value| {
            if (!joined) value.join();
        }
        TestHooks.after_target_authorization = null;
    }
    var worker = PausedInspect{ .host = host };
    thread = try std.Thread.spawn(.{}, PausedInspect.run, .{&worker});
    try barrier.waitUntilEntered();

    var reparent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = AuthorizationRaceIds.target,
        .parent_id = AuthorizationRaceIds.replacement,
    } });
    defer reparent.deinit(alloc);
    var reparented = try host.manager.execute(alloc, reparent, .{
        .actor_id = AuthorizationRaceIds.root,
        .operation_id = "reparent-before-inspect",
        .relationship_authorization = .direct,
        .timestamp_ms = 2,
    });
    defer reparented.deinit(alloc);
    try std.testing.expect(reparented == .receipt);

    barrier.release.store(true, .seq_cst);
    thread.?.join();
    joined = true;
    try std.testing.expect(worker.failure == null);
    const encoded = worker.result orelse return error.TestUnexpectedResult;
    defer std.heap.c_allocator.free(encoded);
    try std.testing.expect(
        std.mem.find(u8, encoded, "private target configuration") == null,
    );
    try std.testing.expect(
        std.mem.find(u8, encoded, "\"error_code\":\"child_unavailable\"") != null,
    );
}

test "configure revalidates target ancestry after a stale attachment snapshot" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, AuthorizationRaceIds.root);
    var test_authority = TestAuthority{ .root_id = AuthorizationRaceIds.root };
    var host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        AuthorizationRaceIds.root,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    try createAuthorizationRaceTree(alloc, &env, &host.manager);

    var barrier = TargetAuthorizationBarrier{};
    TestHooks.after_target_authorization = barrier.hook();
    var thread: ?std.Thread = null;
    var joined = false;
    defer {
        barrier.release.store(true, .seq_cst);
        if (thread) |value| {
            if (!joined) value.join();
        }
        TestHooks.after_target_authorization = null;
    }
    var worker = PausedConfigure{ .host = host };
    thread = try std.Thread.spawn(.{}, PausedConfigure.run, .{&worker});
    try barrier.waitUntilEntered();

    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = AuthorizationRaceIds.target,
    } });
    defer detach.deinit(alloc);
    var detached = try host.manager.execute(alloc, detach, .{
        .actor_id = AuthorizationRaceIds.root,
        .operation_id = "detach-before-configure",
        .timestamp_ms = 2,
    });
    defer detached.deinit(alloc);
    try std.testing.expect(detached == .receipt);

    barrier.release.store(true, .seq_cst);
    thread.?.join();
    joined = true;
    try std.testing.expect(worker.failure == null);
    const encoded = worker.result orelse return error.TestUnexpectedResult;
    defer std.heap.c_allocator.free(encoded);
    try std.testing.expect(
        std.mem.find(u8, encoded, "\"error_code\":\"child_unavailable\"") != null,
    );

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        AuthorizationRaceIds.target,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = AuthorizationRaceIds.target,
    };
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expect(record.parent_id == null);
    try std.testing.expectEqualStrings(
        "private target configuration",
        record.configuration.name,
    );
}

test "configure revalidates live parent permission before commit" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, AuthorizationRaceIds.root);
    var test_authority = TestAuthority{ .root_id = AuthorizationRaceIds.root };
    var host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        AuthorizationRaceIds.root,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    try createAuthorizationRaceTree(alloc, &env, &host.manager);
    const target_generation_before = blk: {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            AuthorizationRaceIds.target,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = AuthorizationRaceIds.target,
        };
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        break :blk record.generation;
    };

    var barrier = TargetAuthorizationBarrier{};
    TestHooks.after_target_authorization = barrier.hook();
    var thread: ?std.Thread = null;
    var joined = false;
    defer {
        barrier.release.store(true, .seq_cst);
        if (thread) |value| {
            if (!joined) value.join();
        }
        TestHooks.after_target_authorization = null;
    }
    var worker = PausedPermissionConfigure{ .host = host };
    thread = try std.Thread.spawn(.{}, PausedPermissionConfigure.run, .{&worker});
    try barrier.waitUntilEntered();

    var downgrade_parent = try domain.validateCommand(alloc, .{ .configure = .{
        .id = AuthorizationRaceIds.actor,
        .permission_mode = .ask,
    } });
    defer downgrade_parent.deinit(alloc);
    var downgraded = try host.manager.execute(alloc, downgrade_parent, .{
        .actor_id = AuthorizationRaceIds.root,
        .operation_id = "downgrade-parent-before-configure",
        .target_authorization = .{ .attached_to_root = AuthorizationRaceIds.root },
        .timestamp_ms = 2,
    });
    defer downgraded.deinit(alloc);
    try std.testing.expect(downgraded == .receipt);

    barrier.release.store(true, .seq_cst);
    thread.?.join();
    joined = true;
    try std.testing.expect(worker.failure == null);
    const encoded = worker.result orelse return error.TestUnexpectedResult;
    defer std.heap.c_allocator.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "permission_escalation") != null);
    var after = try host.authority_resolver.resolve(
        alloc,
        AuthorizationRaceIds.target,
    );
    defer after.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.yolo, after.permission_mode);
    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        AuthorizationRaceIds.target,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = AuthorizationRaceIds.target,
    };
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqual(target_generation_before, record.generation);
}

fn resultChildIdAlloc(alloc: Allocator, result_json: []const u8) ![]u8 {
    return resultStringAlloc(alloc, result_json, "child_id");
}

fn resultOperationIdAlloc(alloc: Allocator, result_json: []const u8) ![]u8 {
    return resultStringAlloc(alloc, result_json, "operation_id");
}

fn createHeldCancellationTestChild(
    alloc: Allocator,
    host: *Runtime,
    root_id: []const u8,
    invocation_id: []const u8,
    name: []const u8,
    prompt: []const u8,
    cancelled_delivery_enabled: bool,
) ![]u8 {
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
        .prompt = prompt,
        .notifications = .{
            .terminal = .{
                .completed = false,
                .failed = false,
                .cancelled = cancelled_delivery_enabled,
            },
            .stop_conditions = &.{.terminal},
        },
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, invocation_id),
    );
    defer alloc.free(created);
    return resultChildIdAlloc(alloc, created);
}

fn terminalDeliveryCount(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    state: domain.State,
) !usize {
    var capability = try sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    var count: usize = 0;
    for (ledger.deliveries) |delivery| switch (delivery.payload) {
        .terminal => |terminal| if (terminal == state) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn resultStringAlloc(
    alloc: Allocator,
    result_json: []const u8,
    key: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result_json, .{});
    defer parsed.deinit();
    const raw = parsed.value.object.get(key) orelse return error.TestUnexpectedResult;
    if (raw != .string) return error.TestUnexpectedResult;
    return alloc.dupe(u8, raw.string);
}

test "tool host materializes defaults and executes canonical persistent branches" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{
        .root_id = root_id,
        .tools = &.{ "read_file", "subagent" },
    };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    const created = try host.execute(alloc, &create, testOptions(root_id, "create-worker"));
    defer alloc.free(created);
    try std.testing.expect(std.mem.find(u8, created, "\"ok\":true") != null);
    const create_operation_id = try resultOperationIdAlloc(alloc, created);
    defer alloc.free(create_operation_id);
    const create_identity = tool_result.parseBoundOperationId(create_operation_id).?;
    try std.testing.expectEqual(domain.OperationIdentitySource.model, create_identity.source);
    try std.testing.expectEqual(domain.OperationIdentityAuthority.manager, create_identity.authority);
    try std.testing.expectEqual(@as(u64, 1), create_identity.epoch);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{ .status, .configuration, .relationship },
    } });
    defer inspect.deinit(alloc);
    const inspected = try host.execute(alloc, &inspect, testOptions(root_id, "inspect-worker"));
    defer alloc.free(inspected);
    try std.testing.expect(std.mem.find(u8, inspected, "test/model") != null);
    try std.testing.expect(std.mem.find(u8, inspected, "\"cursor\":null") != null);

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "renamed-worker",
    } });
    defer configure.deinit(alloc);
    const configured = try host.execute(alloc, &configure, testOptions(root_id, "configure-worker"));
    defer alloc.free(configured);
    try std.testing.expect(std.mem.find(u8, configured, "\"ok\":true") != null);

    var lifecycle = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .close,
    } });
    defer lifecycle.deinit(alloc);
    const closed = try host.execute(alloc, &lifecycle, testOptions(root_id, "close-worker"));
    defer alloc.free(closed);
    try std.testing.expect(std.mem.find(u8, closed, "\"ok\":true") != null);
}

test "accepted tool host cancellation signals live work before cleanup can fail" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = ReleasableLiveChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = ReleasableLiveChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "cancelled-worker",
        .mode = .persistent,
        .prompt = "stay active until cancelled",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-cancelled-worker"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(&runner.entered, 1);

    var busy_lock = AlwaysBusyControlLock{};
    host.owner.child_store_options = busy_lock.options();
    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    const cancelled = try host.execute(
        alloc,
        &cancel,
        testOptions(root_id, "cancel-live-worker"),
    );
    defer alloc.free(cancelled);
    try std.testing.expect(std.mem.find(u8, cancelled, "\"ok\":true") != null);

    const deadline = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline) {
        var live = try host.owner.snapshotLivePresentation(alloc, child_id);
        if (live == null) break;
        live.?.deinit(alloc);
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(
        (try host.owner.snapshotLivePresentation(alloc, child_id)) == null,
    );
    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.cancelled, record.queue[0].status);
}

test "model lifecycle cancellation publishes before a held worker exits" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var held = HeldCancellationChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &held, .run_fn = HeldCancellationChild.run },
    );
    var host_live = true;
    defer {
        held.release.store(true, .seq_cst);
        if (host_live) host.deinit();
    }

    const child_id = try createHeldCancellationTestChild(
        alloc,
        host,
        root_id,
        "create-held-model-cancel",
        "held-model-cancel",
        "wait for model cancellation",
        true,
    );
    defer alloc.free(child_id);
    try held.waitFor(1);

    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    var options = testOptions(root_id, "cancel-held-model-worker");
    options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        options.invocation_id,
        .model,
    );
    const first = try host.execute(alloc, &cancel, options);
    defer alloc.free(first);
    try std.testing.expect(std.mem.find(u8, first, "\"ok\":true") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        try terminalDeliveryCount(alloc, &env.store, child_id, .cancelled),
    );
    var live = try host.owner.snapshotLivePresentation(alloc, child_id);
    defer if (live) |*presentation| presentation.deinit(alloc);
    try std.testing.expect(live != null);

    const replay = try host.execute(alloc, &cancel, options);
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expectEqual(
        @as(usize, 1),
        try terminalDeliveryCount(alloc, &env.store, child_id, .cancelled),
    );

    held.release.store(true, .seq_cst);
    try std.testing.expectEqual(
        execution.ChildResult.cancelled,
        try host.owner.join(child_id),
    );
    host.deinit();
    host_live = false;

    const restarted = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer restarted.deinit();
    _ = try restarted.reconcileAfterRestart(30);
    try std.testing.expectEqual(
        @as(usize, 1),
        try terminalDeliveryCount(alloc, &env.store, child_id, .cancelled),
    );
}

test "human lifecycle cancellation publishes enabled delivery and suppresses disabled delivery" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var held = HeldCancellationChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &held, .run_fn = HeldCancellationChild.run },
    );
    defer {
        held.release.store(true, .seq_cst);
        host.deinit();
    }

    const enabled_child_id = try createHeldCancellationTestChild(
        alloc,
        host,
        root_id,
        "create-held-human-cancel",
        "held-human-cancel-enabled",
        "wait for human cancellation",
        true,
    );
    defer alloc.free(enabled_child_id);
    const disabled_child_id = try createHeldCancellationTestChild(
        alloc,
        host,
        root_id,
        "create-held-disabled-cancel",
        "held-human-cancel-disabled",
        "wait for disabled cancellation",
        false,
    );
    defer alloc.free(disabled_child_id);
    try held.waitFor(2);

    var enabled_cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = enabled_child_id,
        .action = .cancel,
    } });
    defer enabled_cancel.deinit(alloc);
    var enabled_options = testHumanOptions("cancel-held-human-worker");
    enabled_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        enabled_options.invocation_id,
        .human,
    );
    var enabled_result = try host.executeHumanCommand(
        alloc,
        &enabled_cancel,
        enabled_options,
    );
    defer enabled_result.deinit(alloc);
    try std.testing.expect(enabled_result == .receipt);
    try std.testing.expectEqual(
        @as(usize, 1),
        try terminalDeliveryCount(
            alloc,
            &env.store,
            enabled_child_id,
            .cancelled,
        ),
    );

    var disabled_cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = disabled_child_id,
        .action = .cancel,
    } });
    defer disabled_cancel.deinit(alloc);
    var disabled_result = try host.executeHumanCommand(
        alloc,
        &disabled_cancel,
        testHumanOptions("cancel-held-disabled-worker"),
    );
    defer disabled_result.deinit(alloc);
    try std.testing.expect(disabled_result == .receipt);
    try std.testing.expectEqual(
        @as(usize, 0),
        try terminalDeliveryCount(
            alloc,
            &env.store,
            disabled_child_id,
            .cancelled,
        ),
    );

    held.release.store(true, .seq_cst);
    try std.testing.expectEqual(
        execution.ChildResult.cancelled,
        try host.owner.join(enabled_child_id),
    );
    try std.testing.expectEqual(
        execution.ChildResult.cancelled,
        try host.owner.join(disabled_child_id),
    );
}

test "tool host cancellation retry completes fail-once approval cleanup" {
    const FailOncePersistence = struct {
        base: approval_registry.Persistence,
        invalidate_calls: usize = 0,

        fn register(
            raw: ?*anyopaque,
            input: communication.ApprovalInput,
        ) approval_registry.PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.base.register_fn(self.base.context, input);
        }

        fn commit(
            raw: ?*anyopaque,
            response: communication.ApprovalResponse,
            identity_fingerprint: [32]u8,
        ) approval_registry.PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.base.commit_response_fn(
                self.base.context,
                response,
                identity_fingerprint,
            );
        }

        fn invalidate(
            raw: ?*anyopaque,
            request_id: []const u8,
            child_id: []const u8,
            status: communication.ApprovalStatus,
            timestamp_ms: i64,
        ) approval_registry.PersistenceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.invalidate_calls += 1;
            if (self.invalidate_calls == 1) return error.CommitFailed;
            return self.base.invalidate_fn(
                self.base.context,
                request_id,
                child_id,
                status,
                timestamp_ms,
            );
        }

        fn interface(self: *@This()) approval_registry.Persistence {
            return .{
                .context = self,
                .register_fn = register,
                .commit_response_fn = commit,
                .invalidate_fn = invalidate,
            };
        }
    };

    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    const approval_id = "cancel-cleanup-approval";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "cleanup-retry-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-cleanup-retry-worker"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    var send = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "remain pending until cancellation",
    } } });
    defer send.deinit(alloc);
    const send_epoch = try host.issueOperationIdentity(
        alloc,
        "queue-cleanup-retry-worker",
        .model,
    );
    const send_operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        "queue-cleanup-retry-worker",
        .model,
        send_epoch,
    );
    defer alloc.free(send_operation_id);
    var queued = try host.manager.execute(alloc, send, .{
        .actor_id = root_id,
        .operation_id = send_operation_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = send_epoch,
        .operation_identity_admitted = true,
        .timestamp_ms = 10,
    });
    defer queued.deinit(alloc);
    try std.testing.expect(queued == .receipt);

    try host.approvals.registerRelationship(
        approval_id,
        child_id,
        root_id,
        .attach,
        root_id,
        approval_id,
        "pending relationship",
        true,
        11,
    );
    var fail_once = FailOncePersistence{
        .base = host.durable_approvals.interface(),
    };
    host.approvals.persistence = fail_once.interface();

    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    var options = testOptions(root_id, "cancel-cleanup-retry");
    options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        options.invocation_id,
        .model,
    );
    const operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        options.invocation_id,
        .model,
        options.identity_epoch,
    );
    defer alloc.free(operation_id);

    try std.testing.expectError(
        error.ControlStoreFailed,
        host.execute(alloc, &cancel, options),
    );
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        operation_id,
    ));

    const retry = try host.execute(alloc, &cancel, options);
    defer alloc.free(retry);
    try std.testing.expect(std.mem.find(u8, retry, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, retry, operation_id) != null);
    try std.testing.expectEqual(@as(usize, 2), fail_once.invalidate_calls);
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        operation_id,
    ));

    const replay = try host.execute(alloc, &cancel, options);
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(retry, replay);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try communication_state.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.cancelled,
        communication.findApproval(ledger.approvals, approval_id).?.status,
    );
}

test "human manager adapter shares typed create configure relationship and lifecycle effects" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    try env.createSession(alloc, "other-parent");
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "human-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var create_options = testHumanOptions("human-create");
    create_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        create_options.invocation_id,
        .human,
    );
    var created = try host.executeHumanCommand(alloc, &create, create_options);
    defer created.deinit(alloc);
    try std.testing.expect(created == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.created, created.receipt.code);
    try std.testing.expectEqualStrings("test/model", create.create.configuration.model.?);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), create.create.configuration.effort.?);
    const child_id = try alloc.dupe(u8, created.receipt.target_id);
    defer alloc.free(child_id);

    var replay = try host.executeHumanCommand(alloc, &create, create_options);
    defer replay.deinit(alloc);
    try std.testing.expect(replay == .receipt);
    try std.testing.expectEqualStrings(child_id, replay.receipt.target_id);
    try std.testing.expectEqual(created.receipt.generation, replay.receipt.generation);

    var already_parented = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = child_id,
        .parent_id = "other-parent",
    } });
    defer already_parented.deinit(alloc);
    var already_parented_result = try host.executeHumanCommand(
        alloc,
        &already_parented,
        .{
            .invocation_id = "human-already-parented",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = created.receipt.generation,
            .timestamp_ms = 15,
        },
    );
    defer already_parented_result.deinit(alloc);
    try std.testing.expect(already_parented_result == .failure);
    try std.testing.expectEqual(
        manager_mod.FailureCode.relationship_already_parented,
        already_parented_result.failure.code,
    );

    var attach_descendant = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "other-parent",
        .parent_id = child_id,
    } });
    defer attach_descendant.deinit(alloc);
    var descendant_result = try host.executeHumanCommand(
        alloc,
        &attach_descendant,
        .{
            .invocation_id = "human-attach-descendant",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = 0,
            .timestamp_ms = 16,
        },
    );
    defer descendant_result.deinit(alloc);
    try std.testing.expect(descendant_result == .receipt);

    var cycle = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = child_id,
        .parent_id = "other-parent",
    } });
    defer cycle.deinit(alloc);
    var cycle_result = try host.executeHumanCommand(
        alloc,
        &cycle,
        .{
            .invocation_id = "human-cycle",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = created.receipt.generation,
            .timestamp_ms = 17,
        },
    );
    defer cycle_result.deinit(alloc);
    try std.testing.expect(cycle_result == .failure);
    try std.testing.expectEqual(manager_mod.FailureCode.relationship_cycle, cycle_result.failure.code);

    var detach_descendant = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "other-parent",
    } });
    defer detach_descendant.deinit(alloc);
    var descendant_detached = try host.executeHumanCommand(
        alloc,
        &detach_descendant,
        .{
            .invocation_id = "human-detach-descendant",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = descendant_result.receipt.generation,
            .timestamp_ms = 18,
        },
    );
    defer descendant_detached.deinit(alloc);
    try std.testing.expect(descendant_detached == .receipt);

    var missing = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "missing-id",
    } });
    defer missing.deinit(alloc);
    var missing_result = try host.executeHumanCommand(
        alloc,
        &missing,
        testHumanOptions("human-missing"),
    );
    defer missing_result.deinit(alloc);
    try std.testing.expect(missing_result == .failure);
    try std.testing.expectEqual(manager_mod.FailureCode.session_not_found, missing_result.failure.code);

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "renamed-by-human",
    } });
    defer configure.deinit(alloc);
    var configure_options = HumanCommandOptions{
        .invocation_id = "human-configure",
        .defaults = testHumanOptions("unused").defaults,
        .expected_generation = created.receipt.generation,
        .timestamp_ms = 20,
    };
    configure_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        configure_options.invocation_id,
        .human,
    );
    var configured = try host.executeHumanCommand(alloc, &configure, configure_options);
    defer configured.deinit(alloc);
    try std.testing.expect(configured == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.configured, configured.receipt.code);

    var conflict = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "conflicting-name",
    } });
    defer conflict.deinit(alloc);
    var conflict_options = configure_options;
    conflict_options.expected_generation = configured.receipt.generation;
    conflict_options.timestamp_ms = 25;
    var conflict_result = try host.executeHumanCommand(alloc, &conflict, conflict_options);
    defer conflict_result.deinit(alloc);
    try std.testing.expect(conflict_result == .failure);
    try std.testing.expectEqual(manager_mod.FailureCode.operation_conflict, conflict_result.failure.code);

    var stale = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "stale-name",
    } });
    defer stale.deinit(alloc);
    var stale_result = try host.executeHumanCommand(
        alloc,
        &stale,
        .{
            .invocation_id = "human-configure-stale",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = created.receipt.generation,
            .timestamp_ms = 30,
        },
    );
    defer stale_result.deinit(alloc);
    try std.testing.expect(stale_result == .failure);
    try std.testing.expectEqual(manager_mod.FailureCode.stale_generation, stale_result.failure.code);

    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = child_id,
    } });
    defer detach.deinit(alloc);
    var detached = try host.executeHumanCommand(
        alloc,
        &detach,
        .{
            .invocation_id = "human-detach",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = configured.receipt.generation,
            .timestamp_ms = 40,
        },
    );
    defer detached.deinit(alloc);
    try std.testing.expect(detached == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, detached.receipt.code);

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = child_id,
    } });
    defer attach.deinit(alloc);
    var attached = try host.executeHumanCommand(
        alloc,
        &attach,
        .{
            .invocation_id = "human-attach",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = detached.receipt.generation,
            .timestamp_ms = 50,
        },
    );
    defer attached.deinit(alloc);
    try std.testing.expect(attached == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, attached.receipt.code);

    var close = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .close,
    } });
    defer close.deinit(alloc);
    var closed = try host.executeHumanCommand(
        alloc,
        &close,
        .{
            .invocation_id = "human-close",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = attached.receipt.generation,
            .timestamp_ms = 60,
        },
    );
    defer closed.deinit(alloc);
    try std.testing.expect(closed == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.lifecycle_changed, closed.receipt.code);

    var reopen = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .reopen,
    } });
    defer reopen.deinit(alloc);
    var reopened = try host.executeHumanCommand(
        alloc,
        &reopen,
        .{
            .invocation_id = "human-reopen",
            .defaults = testHumanOptions("unused").defaults,
            .expected_generation = closed.receipt.generation,
            .timestamp_ms = 70,
        },
    );
    defer reopened.deinit(alloc);
    try std.testing.expect(reopened == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.lifecycle_changed, reopened.receipt.code);
}

test "human inspections and stable failures leave no mutation reservations" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "reservation-fixture",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try host.executeHumanCommand(
        alloc,
        &create,
        testHumanOptions("human-reservation-fixture"),
    );
    defer created.deinit(alloc);
    try std.testing.expect(created == .receipt);
    const child_id = try alloc.dupe(u8, created.receipt.target_id);
    defer alloc.free(child_id);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
    } });
    defer inspect.deinit(alloc);
    for (0..3) |index| {
        var invocation_buffer: [64]u8 = undefined;
        const invocation_id = try std.fmt.bufPrint(
            &invocation_buffer,
            "human-inspect-{d}",
            .{index},
        );
        var inspected = try host.executeHumanCommand(
            alloc,
            &inspect,
            testHumanOptions(invocation_id),
        );
        defer inspected.deinit(alloc);
        try std.testing.expect(inspected == .inspection);
    }

    var missing = try domain.validateCommand(alloc, .{ .configure = .{
        .id = "01J00000000000000000009999",
        .name = "never applied",
    } });
    defer missing.deinit(alloc);
    for (0..3) |index| {
        var invocation_buffer: [64]u8 = undefined;
        const invocation_id = try std.fmt.bufPrint(
            &invocation_buffer,
            "stable-human-failure-{d}",
            .{index},
        );
        var rejected = try host.executeHumanCommand(
            alloc,
            &missing,
            testHumanOptions(invocation_id),
        );
        defer rejected.deinit(alloc);
        try std.testing.expect(rejected == .failure);
        try std.testing.expectEqual(
            manager_mod.FailureCode.child_unavailable,
            rejected.failure.code,
        );
        try std.testing.expect(!rejected.failure.retryable);
    }

    var configure = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "still writable",
    } });
    defer configure.deinit(alloc);
    var configured = try host.executeHumanCommand(
        alloc,
        &configure,
        testHumanOptions("human-mutation-after-stable-failures"),
    );
    defer configured.deinit(alloc);
    try std.testing.expect(configured == .receipt);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer capability.deinit();
    const store = create_store.Store{
        .capability = &capability,
        .expected_root_id = root_id,
    };
    var identities = (try store.loadOptional(alloc)).?;
    defer identities.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        identities.outstanding_operations.len,
    );
}

test "tool host creates stable approval intent before attach effects" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "detached-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    const created = try host.execute(alloc, &create, testOptions(root_id, "create-detached"));
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = child_id,
    } });
    defer detach.deinit(alloc);
    const detached = try host.execute(alloc, &detach, testOptions(root_id, "detach-worker"));
    defer alloc.free(detached);
    try std.testing.expect(std.mem.find(u8, detached, "\"ok\":true") != null);

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = child_id,
    } });
    defer attach.deinit(alloc);
    var attach_options = testOptions(root_id, "attach-worker");
    attach_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        attach_options.invocation_id,
        .model,
    );
    const first = try host.execute(alloc, &attach, attach_options);
    defer alloc.free(first);
    try std.testing.expect(std.mem.find(u8, first, "\"status\":\"awaiting_approval\"") != null);
    const attach_operation_id = try resultOperationIdAlloc(alloc, first);
    defer alloc.free(attach_operation_id);
    try std.testing.expect(std.mem.find(u8, first, attach_operation_id) != null);

    const replay = try host.execute(alloc, &attach, attach_options);
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(first, replay);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
    } });
    defer inspect.deinit(alloc);
    const unavailable = try host.execute(alloc, &inspect, testOptions(root_id, "inspect-detached"));
    defer alloc.free(unavailable);
    try std.testing.expect(std.mem.find(u8, unavailable, "\"error_code\":\"child_unavailable\"") != null);

    try std.testing.expectEqual(
        approval_registry.ResolveResult.accepted,
        try host.resolveApproval(.{
            .request_id = attach_operation_id,
            .child_id = child_id,
            .decision = .once,
            .timestamp_ms = 11,
        }),
    );
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        attach_operation_id,
    ));
    const available = try host.execute(
        alloc,
        &inspect,
        testOptions(root_id, "inspect-attached"),
    );
    defer alloc.free(available);
    try std.testing.expect(std.mem.find(u8, available, "\"ok\":true") != null);
}

test "relationship approval denial retires its operation identity" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "approval-retirement-fixture",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-approval-retirement-fixture"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = child_id,
    } });
    defer detach.deinit(alloc);
    const detached = try host.execute(
        alloc,
        &detach,
        testOptions(root_id, "detach-approval-retirement-fixture"),
    );
    defer alloc.free(detached);

    var attach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = child_id,
    } });
    defer attach.deinit(alloc);
    var options = testOptions(root_id, "denied-relationship-operation");
    options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        options.invocation_id,
        .model,
    );
    const intent = try host.execute(alloc, &attach, options);
    defer alloc.free(intent);
    const operation_id = try resultOperationIdAlloc(alloc, intent);
    defer alloc.free(operation_id);
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        operation_id,
    ));

    try std.testing.expectEqual(
        approval_registry.ResolveResult.accepted,
        try host.resolveApproval(.{
            .request_id = operation_id,
            .child_id = child_id,
            .decision = .deny,
            .timestamp_ms = 20,
        }),
    );
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        operation_id,
    ));

    const expired = try host.execute(alloc, &attach, options);
    defer alloc.free(expired);
    try std.testing.expect(
        std.mem.find(
            u8,
            expired,
            "\"error_code\":\"operation_replay_expired\"",
        ) != null,
    );
}

test "tool host finalizes a consumed reparent without applying the edge twice" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var parent_command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "new-parent",
        .mode = .persistent,
    } });
    defer parent_command.deinit(alloc);
    const parent_result = try host.execute(
        alloc,
        &parent_command,
        testOptions(root_id, "create-new-parent"),
    );
    defer alloc.free(parent_result);
    const parent_id = try resultChildIdAlloc(alloc, parent_result);
    defer alloc.free(parent_id);

    var child_command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "moving-child",
        .mode = .persistent,
    } });
    defer child_command.deinit(alloc);
    const child_result = try host.execute(
        alloc,
        &child_command,
        testOptions(root_id, "create-moving-child"),
    );
    defer alloc.free(child_result);
    const child_id = try resultChildIdAlloc(alloc, child_result);
    defer alloc.free(child_id);

    var before_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer before_capability.deinit();
    const before_store = control_store.Store{
        .capability = &before_capability,
        .expected_child_id = child_id,
    };
    var before_record = try before_store.load(alloc);
    defer before_record.deinit(alloc);
    const generation_before = before_record.generation;
    const event_count_before = before_record.events.len;

    var reparent = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = child_id,
        .parent_id = parent_id,
    } });
    defer reparent.deinit(alloc);
    var reparent_options = testOptions(root_id, "reparent-child");
    reparent_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        reparent_options.invocation_id,
        .model,
    );
    const intent = try host.execute(alloc, &reparent, reparent_options);
    defer alloc.free(intent);
    try std.testing.expect(std.mem.find(u8, intent, "awaiting_approval") != null);
    const reparent_operation_id = try resultOperationIdAlloc(alloc, intent);
    defer alloc.free(reparent_operation_id);
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        reparent_operation_id,
    ));
    const resolution_options: ApprovalResolveOptions = .{
        .request_id = reparent_operation_id,
        .child_id = child_id,
        .decision = .once,
        .timestamp_ms = 11,
    };
    try std.testing.expectEqual(
        approval_registry.ResolveResult.relationship_ready,
        try host.approvals.resolve(
            resolution_options.request_id,
            resolution_options.child_id,
            resolution_options.decision,
            resolution_options.feedback,
            resolution_options.timestamp_ms,
        ),
    );
    var applied = try host.manager.execute(alloc, reparent, .{
        .actor_id = root_id,
        .operation_id = reparent_operation_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = reparent_options.identity_epoch,
        .operation_identity_admitted = true,
        .relationship_authorization = .{
            .approval = reparent_operation_id,
        },
        .timestamp_ms = 11,
    });
    defer applied.deinit(alloc);
    try std.testing.expect(applied == .receipt);
    try std.testing.expectEqual(
        approval_registry.ResolveResult.accepted,
        try host.continueApprovedRelationship(resolution_options),
    );
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        reparent_operation_id,
    ));

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var record = try store.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqualStrings(parent_id, record.parent_id.?);
    try std.testing.expectEqual(generation_before + 1, record.generation);
    try std.testing.expectEqual(event_count_before + 1, record.events.len);

    const communication_store_value = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try communication_store_value.load(alloc);
    defer ledger.deinit(alloc);
    const approval = communication.findApproval(
        ledger.approvals,
        reparent_operation_id,
    ) orelse return error.TestApprovalMissing;
    try std.testing.expectEqual(
        communication.ApprovalStatus.consumed,
        approval.status,
    );
    try std.testing.expectError(
        error.RequestNotFound,
        host.resolveApproval(.{
            .request_id = reparent_operation_id,
            .child_id = child_id,
            .decision = .once,
            .timestamp_ms = 12,
        }),
    );
}

const BlockingChild = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        _: *execution.TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *BlockingChild = @ptrCast(@alignCast(raw.?));
        self.started.store(true, .seq_cst);
        while (!cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        return error.Cancelled;
    }
};

test "tool host exit joins active work and persists interruption" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var blocking = BlockingChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &blocking, .run_fn = BlockingChild.run },
    );
    var host_live = true;
    defer if (host_live) host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "active-worker",
        .mode = .persistent,
        .prompt = "wait for host exit",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(alloc, &create, testOptions(root_id, "create-active"));
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    const deadline = io_mod.milliTimestamp() + 5_000;
    while (!blocking.started.load(.seq_cst) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(blocking.started.load(.seq_cst));
    host.deinit();
    host_live = false;

    var resumed_runner = CountingChild{};
    const recovered = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &resumed_runner, .run_fn = CountingChild.run },
    );
    defer recovered.deinit();
    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
    } });
    defer inspect.deinit(alloc);
    const inspected = try recovered.execute(alloc, &inspect, testOptions(root_id, "inspect-interrupted"));
    defer alloc.free(inspected);
    try std.testing.expect(std.mem.find(u8, inspected, "\"status\":\"interrupted\"") != null);

    var resume_command = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .@"resume",
    } });
    defer resume_command.deinit(alloc);
    const resumed = try recovered.execute(alloc, &resume_command, testOptions(root_id, "resume-interrupted"));
    defer alloc.free(resumed);
    try std.testing.expect(std.mem.find(u8, resumed, "\"ok\":true") != null);
    try resumed_runner.waitFor(1);

    var close = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .close,
    } });
    defer close.deinit(alloc);
    const closed = try recovered.execute(alloc, &close, testOptions(root_id, "close-resumed"));
    defer alloc.free(closed);
    try std.testing.expect(std.mem.find(u8, closed, "\"ok\":true") != null);
    var reopen = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .reopen,
    } });
    defer reopen.deinit(alloc);
    const reopened = try recovered.execute(alloc, &reopen, testOptions(root_id, "reopen-resumed"));
    defer alloc.free(reopened);
    try std.testing.expect(std.mem.find(u8, reopened, "\"ok\":true") != null);
    var final_inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
    } });
    defer final_inspect.deinit(alloc);
    const final_state = try recovered.execute(
        alloc,
        &final_inspect,
        testOptions(root_id, "inspect-reopened"),
    );
    defer alloc.free(final_state);
    try std.testing.expect(std.mem.find(u8, final_state, "\"status\":\"idle\"") != null);
}

test "manager refresh reconciles restart once without replaying unfinished work" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const initial = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "restart-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    const created = try initial.execute(alloc, &create, testOptions(root_id, "create-restart-worker"));
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);

    var send = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "unfinished across restart",
    } } });
    defer send.deinit(alloc);
    const admission_id = try tool_result.boundOperationIdAlloc(
        alloc,
        "admit-restart-work",
        .model,
        1,
    );
    defer alloc.free(admission_id);
    var admitted = try initial.manager.execute(alloc, send, .{
        .actor_id = root_id,
        .operation_id = admission_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 1,
        .operation_identity_admitted = true,
        .timestamp_ms = 20,
    });
    defer admitted.deinit(alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(alloc, child_id, .{});
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try store.acquireLock();
    var record = try store.load(alloc);
    try execution.admitWork(alloc, &record, 0, 21);
    try store.save(alloc, record);
    record.deinit(alloc);
    lock.release();
    initial.deinit();

    var runner = CountingChild{};
    const recovered = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = CountingChild.run },
    );
    defer recovered.deinit();
    const report = try recovered.reconcileAfterRestart(30);
    try std.testing.expectEqual(@as(usize, 1), report.sessions_changed);
    try std.testing.expectEqual(@as(usize, 1), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), runner.completed.load(.seq_cst));
    const repeated = try recovered.reconcileAfterRestart(31);
    try std.testing.expectEqual(@as(usize, 0), repeated.sessions_changed);
    try std.testing.expectEqual(@as(usize, 0), repeated.work_interrupted);

    var interrupted = try store.load(alloc);
    defer interrupted.deinit(alloc);
    try std.testing.expectEqual(domain.State.interrupted, interrupted.state);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, interrupted.queue[0].status);
    try std.testing.expectEqualStrings(
        "interrupted by process restart",
        interrupted.queue[0].cancellation_reason.?,
    );
}

const RecoverySyncBarrier = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *RecoverySyncBarrier = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn waitUntilEntered(self: *RecoverySyncBarrier) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (!self.entered.load(.seq_cst) and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (!self.entered.load(.seq_cst)) return error.TestUnexpectedResult;
    }
};

const ConcurrentRecovery = struct {
    host: *Runtime,
    timestamp_ms: i64,
    ready: *std.atomic.Value(usize),
    start: *std.atomic.Value(bool),
    completed: *std.atomic.Value(usize),
    report: execution.RecoveryReport = .{},
    failure: ?anyerror = null,

    fn run(self: *ConcurrentRecovery) void {
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (!self.start.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.report = self.host.reconcileAfterRestart(self.timestamp_ms) catch |err| {
            self.failure = err;
            _ = self.completed.fetchAdd(1, .seq_cst);
            return;
        };
        _ = self.completed.fetchAdd(1, .seq_cst);
    }
};

test "recovery policy admits one automatic pass and explicit-only retries" {
    const StartCase = struct {
        state: RecoveryState,
        trigger: RecoveryTrigger,
        expected: RecoveryStartDecision,
    };
    const start_cases = [_]StartCase{
        .{ .state = .pending, .trigger = .automatic, .expected = .schedule },
        .{ .state = .pending, .trigger = .explicit, .expected = .start },
        .{ .state = .scheduled, .trigger = .automatic, .expected = .no_effect },
        .{ .state = .scheduled, .trigger = .explicit, .expected = .wait },
        .{ .state = .running, .trigger = .automatic, .expected = .no_effect },
        .{ .state = .running, .trigger = .explicit, .expected = .wait },
        .{ .state = .deferred, .trigger = .automatic, .expected = .no_effect },
        .{ .state = .deferred, .trigger = .explicit, .expected = .start },
        .{ .state = .complete, .trigger = .automatic, .expected = .no_effect },
        .{ .state = .complete, .trigger = .explicit, .expected = .no_effect },
    };
    for (start_cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            decideRecoveryStart(case.state, case.trigger),
        );
    }

    try std.testing.expectEqual(
        RecoveryState.complete,
        recoveryStateAfterFinish(.fully_reconciled),
    );
    try std.testing.expectEqual(
        RecoveryState.deferred,
        recoveryStateAfterFinish(.incomplete),
    );
    try std.testing.expectEqual(
        RecoveryState.deferred,
        recoveryStateAfterFinish(.failed),
    );
}

test "concurrent first recovery callers serialize one durable transition" {
    const setup_alloc = std.testing.allocator;
    const thread_alloc = std.heap.c_allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(setup_alloc);
    defer env.deinit(setup_alloc);
    try env.createSession(setup_alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const initial = try Runtime.create(
        setup_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );

    var create = try domain.validateCommand(setup_alloc, .{ .create = .{
        .name = "concurrent-recovery-worker",
        .mode = .persistent,
    } });
    defer create.deinit(setup_alloc);
    const created = try initial.execute(
        setup_alloc,
        &create,
        testOptions(root_id, "create-concurrent-recovery-worker"),
    );
    defer setup_alloc.free(created);
    const child_id = try resultChildIdAlloc(setup_alloc, created);
    defer setup_alloc.free(child_id);

    var send = try domain.validateCommand(setup_alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "unfinished concurrent recovery",
    } } });
    defer send.deinit(setup_alloc);
    const admission_id = try tool_result.boundOperationIdAlloc(
        setup_alloc,
        "admit-concurrent-recovery",
        .model,
        1,
    );
    defer setup_alloc.free(admission_id);
    var admitted = try initial.manager.execute(setup_alloc, send, .{
        .actor_id = root_id,
        .operation_id = admission_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 1,
        .operation_identity_admitted = true,
        .timestamp_ms = 20,
    });
    defer admitted.deinit(setup_alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        setup_alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try store.acquireLock();
    var record = try store.load(setup_alloc);
    try execution.admitWork(setup_alloc, &record, 0, 21);
    try store.save(setup_alloc, record);
    const initial_generation = record.generation;
    const initial_event_count = record.events.len;
    record.deinit(setup_alloc);
    lock.release();
    initial.deinit();

    const recovered = try Runtime.create(
        thread_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer recovered.deinit();
    var barrier = RecoverySyncBarrier{};
    recovered.owner.child_store_options = .{ .replace_ops = .{
        .ctx = &barrier,
        .sync_dir = RecoverySyncBarrier.syncDir,
    } };
    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var completed = std.atomic.Value(usize).init(0);
    var first = ConcurrentRecovery{
        .host = recovered,
        .timestamp_ms = 30,
        .ready = &ready,
        .start = &start,
        .completed = &completed,
    };
    var second = ConcurrentRecovery{
        .host = recovered,
        .timestamp_ms = 31,
        .ready = &ready,
        .start = &start,
        .completed = &completed,
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentRecovery.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentRecovery.run, .{&second});
    while (ready.load(.seq_cst) != 2) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    start.store(true, .seq_cst);
    barrier.waitUntilEntered() catch |err| {
        barrier.release.store(true, .seq_cst);
        first_thread.join();
        second_thread.join();
        return err;
    };
    const observation_deadline = io_mod.milliTimestamp() + 100;
    while (completed.load(.seq_cst) == 0 and
        io_mod.milliTimestamp() < observation_deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const completed_while_first_blocked = completed.load(.seq_cst);
    barrier.release.store(true, .seq_cst);
    first_thread.join();
    second_thread.join();

    try std.testing.expectEqual(@as(usize, 0), completed_while_first_blocked);
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        first.report.sessions_changed + second.report.sessions_changed,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        first.report.work_interrupted + second.report.work_interrupted,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        first.report.sessions_external_busy + second.report.sessions_external_busy,
    );
    var recovered_record = try store.load(setup_alloc);
    defer recovered_record.deinit(setup_alloc);
    try std.testing.expectEqual(initial_generation + 1, recovered_record.generation);
    try std.testing.expectEqual(initial_event_count + 1, recovered_record.events.len);
    try std.testing.expectEqual(domain.State.interrupted, recovered_record.state);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, recovered_record.queue[0].status);
}

test "background recovery is single flight while manager projection stays readable" {
    const setup_alloc = std.testing.allocator;
    const runtime_alloc = std.heap.c_allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(setup_alloc);
    defer env.deinit(setup_alloc);
    try env.createSession(setup_alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const initial = try Runtime.create(
        setup_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );

    var create = try domain.validateCommand(setup_alloc, .{ .create = .{
        .name = "background-recovery-worker",
        .mode = .persistent,
    } });
    defer create.deinit(setup_alloc);
    const created = try initial.execute(
        setup_alloc,
        &create,
        testOptions(root_id, "create-background-recovery-worker"),
    );
    defer setup_alloc.free(created);
    const child_id = try resultChildIdAlloc(setup_alloc, created);
    defer setup_alloc.free(child_id);
    var send = try domain.validateCommand(setup_alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "unfinished background recovery",
    } } });
    defer send.deinit(setup_alloc);
    const admission_id = try tool_result.boundOperationIdAlloc(
        setup_alloc,
        "admit-background-recovery",
        .model,
        1,
    );
    defer setup_alloc.free(admission_id);
    var admitted = try initial.manager.execute(setup_alloc, send, .{
        .actor_id = root_id,
        .operation_id = admission_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 1,
        .operation_identity_admitted = true,
        .timestamp_ms = 20,
    });
    defer admitted.deinit(setup_alloc);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        setup_alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    {
        var lock = try store.acquireLock();
        defer lock.release();
        var record = try store.load(setup_alloc);
        defer record.deinit(setup_alloc);
        try execution.admitWork(setup_alloc, &record, 0, 21);
        try store.save(setup_alloc, record);
    }
    initial.deinit();

    const recovered = try Runtime.create(
        runtime_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    var recovery_live = true;
    defer if (recovery_live) recovered.deinit();
    var barrier = RecoverySyncBarrier{};
    recovered.owner.child_store_options = .{ .replace_ops = .{
        .ctx = &barrier,
        .sync_dir = RecoverySyncBarrier.syncDir,
    } };
    var recovery_mutex_locked = false;
    var explicit_thread: ?std.Thread = null;
    defer {
        if (recovery_mutex_locked) recovered.recovery_mutex.unlock(std.testing.io);
        barrier.release.store(true, .seq_cst);
        if (explicit_thread) |thread| thread.join();
    }
    recovered.recovery_mutex.lockUncancelable(std.testing.io);
    recovery_mutex_locked = true;
    try recovered.requestBackgroundRecovery(30);
    try std.testing.expectEqual(RecoveryState.scheduled, recovered.recoveryState());

    var explicit_ready = std.atomic.Value(usize).init(0);
    var explicit_start = std.atomic.Value(bool).init(true);
    var explicit_completed = std.atomic.Value(usize).init(0);
    var explicit = ConcurrentRecovery{
        .host = recovered,
        .timestamp_ms = 31,
        .ready = &explicit_ready,
        .start = &explicit_start,
        .completed = &explicit_completed,
    };
    explicit_thread = try std.Thread.spawn(.{}, ConcurrentRecovery.run, .{&explicit});
    while (explicit_ready.load(.seq_cst) == 0) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const claim_deadline = io_mod.milliTimestamp() + 100;
    while (explicit_completed.load(.seq_cst) == 0 and
        io_mod.milliTimestamp() < claim_deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(@as(usize, 0), explicit_completed.load(.seq_cst));

    recovered.recovery_mutex.unlock(std.testing.io);
    recovery_mutex_locked = false;
    try barrier.waitUntilEntered();
    try std.testing.expectEqual(RecoveryState.running, recovered.recoveryState());

    try recovered.requestBackgroundRecovery(30);
    var projection = try recovered.manager.snapshot(setup_alloc, .{
        .root_id = root_id,
        .limit = domain.max_page_limit,
    });
    defer projection.deinit(setup_alloc);
    switch (projection) {
        .failure => return error.TestUnexpectedResult,
        .snapshot => |snapshot| try std.testing.expectEqual(
            @as(usize, 1),
            snapshot.nodes.len,
        ),
    }

    barrier.release.store(true, .seq_cst);
    explicit_thread.?.join();
    explicit_thread = null;
    try std.testing.expect(explicit.failure == null);
    try std.testing.expectEqual(@as(usize, 0), explicit.report.sessions_changed);
    const deadline = io_mod.milliTimestamp() + 5_000;
    while ((recovered.recoveryState() == .scheduled or
        recovered.recoveryState() == .running) and
        io_mod.milliTimestamp() < deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(RecoveryState.complete, recovered.recoveryState());
    try recovered.requestBackgroundRecovery(31);

    var interrupted = try store.load(setup_alloc);
    defer interrupted.deinit(setup_alloc);
    try std.testing.expectEqual(domain.State.interrupted, interrupted.state);
    try std.testing.expectEqual(
        domain.QueueStatus.interrupted,
        interrupted.queue[0].status,
    );
    recovered.deinit();
    recovery_live = false;
}

test "partial automatic recovery stays deferred until explicit retry" {
    const setup_alloc = std.testing.allocator;
    const runtime_alloc = std.heap.c_allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(setup_alloc);
    defer env.deinit(setup_alloc);
    try env.createSession(setup_alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const initial = try Runtime.create(
        setup_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    var create = try domain.validateCommand(setup_alloc, .{ .create = .{
        .name = "retry-recovery-worker",
        .mode = .persistent,
    } });
    defer create.deinit(setup_alloc);
    const created = try initial.execute(
        setup_alloc,
        &create,
        testOptions(root_id, "create-retry-recovery-worker"),
    );
    defer setup_alloc.free(created);
    const child_id = try resultChildIdAlloc(setup_alloc, created);
    defer setup_alloc.free(child_id);
    var send = try domain.validateCommand(setup_alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "unfinished retry recovery",
    } } });
    defer send.deinit(setup_alloc);
    const admission_id = try tool_result.boundOperationIdAlloc(
        setup_alloc,
        "admit-retry-recovery",
        .model,
        1,
    );
    defer setup_alloc.free(admission_id);
    var admitted = try initial.manager.execute(setup_alloc, send, .{
        .actor_id = root_id,
        .operation_id = admission_id,
        .operation_identity_source = .model,
        .operation_identity_epoch = 1,
        .operation_identity_admitted = true,
        .timestamp_ms = 20,
    });
    defer admitted.deinit(setup_alloc);
    var capability = try env.store.openSubagentControlCapabilityWritable(
        setup_alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var lock = try store.acquireLock();
    var record = try store.load(setup_alloc);
    try execution.admitWork(setup_alloc, &record, 0, 21);
    try store.save(setup_alloc, record);
    record.deinit(setup_alloc);
    lock.release();
    initial.deinit();

    const recovered = try Runtime.create(
        runtime_alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer recovered.deinit();
    var sync_failure = CreateSyncFailure{};
    recovered.owner.child_store_options = .{ .replace_ops = .{
        .ctx = &sync_failure,
        .sync_dir = CreateSyncFailure.syncDir,
    } };
    try recovered.requestBackgroundRecovery(30);
    const deferred_deadline = io_mod.milliTimestamp() + 5_000;
    while ((recovered.recoveryState() == .scheduled or
        recovered.recoveryState() == .running) and
        io_mod.milliTimestamp() < deferred_deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(RecoveryState.deferred, recovered.recoveryState());
    try std.testing.expectEqual(@as(usize, 1), sync_failure.calls);

    try recovered.requestBackgroundRecovery(31);
    try recovered.requestBackgroundRecovery(30_000);
    try std.testing.expectEqual(RecoveryState.deferred, recovered.recoveryState());
    try std.testing.expectEqual(@as(usize, 1), sync_failure.calls);

    var failing = std.testing.FailingAllocator.init(runtime_alloc, .{
        .fail_index = 0,
    });
    recovered.owner.alloc = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        recovered.reconcileAfterRestart(31),
    );
    try std.testing.expectEqual(RecoveryState.deferred, recovered.recoveryState());
    recovered.owner.alloc = runtime_alloc;

    recovered.owner.child_store_options = .{};
    const report = try recovered.reconcileAfterRestart(32);
    try std.testing.expect(report.fullyReconciled());
    try std.testing.expectEqual(RecoveryState.complete, recovered.recoveryState());
    var interrupted = try store.load(setup_alloc);
    defer interrupted.deinit(setup_alloc);
    try std.testing.expectEqual(domain.State.interrupted, interrupted.state);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, interrupted.queue[0].status);
    const repeated = try recovered.reconcileAfterRestart(33);
    try std.testing.expectEqual(@as(usize, 0), repeated.sessions_changed);
}

test "human resume retries a lock-blocked durable enqueue exactly once" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = CountingChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = CountingChild.run },
    );
    defer host.deinit();
    host.owner.session_resume_options = .{
        .log = .{ .session_lock_deadline_ms = 0 },
    };

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "direct-resume-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try host.executeHumanCommand(
        alloc,
        &create,
        testHumanOptions("create-direct-resume-worker"),
    );
    defer created.deinit(alloc);
    const child_id = try alloc.dupe(u8, created.receipt.target_id);
    defer alloc.free(child_id);

    var external_writer = try env.store.resumeForWrite(alloc, child_id);
    var writer_live = true;
    defer if (writer_live) external_writer.deinit(alloc);
    var admitted = try host.sendMessage(alloc, .{
        .caller_id = root_id,
        .invocation_id = "enqueue-under-direct-resume",
        .child_id = child_id,
        .content = "queued while direct resume owns transcript",
        .timestamp_ms = 40,
    });
    defer admitted.deinit(alloc);
    try std.testing.expect(admitted == .receipt);
    try std.testing.expectEqual(
        execution.ChildResult.external_busy,
        try host.owner.join(child_id),
    );
    try std.testing.expectEqual(@as(usize, 0), external_writer.state.history.len);
    try std.testing.expectEqual(@as(usize, 0), runner.completed.load(.seq_cst));
    external_writer.deinit(alloc);
    writer_live = false;

    var resume_command = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .@"resume",
    } });
    defer resume_command.deinit(alloc);
    var resumed = try host.executeHumanCommand(
        alloc,
        &resume_command,
        testHumanOptions("retry-after-direct-resume"),
    );
    defer resumed.deinit(alloc);
    try std.testing.expect(resumed == .receipt);
    try runner.waitFor(1);
    try std.testing.expectEqual(execution.ChildResult.idle, try host.owner.join(child_id));
    try std.testing.expectEqual(@as(usize, 1), runner.completed.load(.seq_cst));

    var completed = try env.store.resumeForWrite(alloc, child_id);
    defer completed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), completed.state.history.len);
    try std.testing.expectEqualStrings(
        "queued while direct resume owns transcript",
        completed.state.history[0].assistant.user.text,
    );
}

test "tool host derives milestone identity from active child work" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var blocking = BlockingChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &blocking, .run_fn = BlockingChild.run },
    );
    defer host.deinit();
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "milestone-worker",
        .mode = .persistent,
        .prompt = "active work",
        .notifications = .{ .milestones = &.{"checkpoint"} },
    } });
    defer create.deinit(alloc);
    const created = try host.execute(alloc, &create, testOptions(root_id, "create-milestone"));
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (!blocking.started.load(.seq_cst) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(blocking.started.load(.seq_cst));

    var milestone = try domain.validateCommand(alloc, .{ .message = .{ .milestone = .{
        .name = "checkpoint",
    } } });
    defer milestone.deinit(alloc);
    const emitted = try host.execute(
        alloc,
        &milestone,
        testOptions(child_id, "emit-checkpoint"),
    );
    defer alloc.free(emitted);
    try std.testing.expect(std.mem.find(u8, emitted, "\"ok\":true") != null);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    var found = false;
    for (ledger.deliveries) |delivery| switch (delivery.payload) {
        .milestone => |name| {
            try std.testing.expectEqualStrings("checkpoint", name);
            try std.testing.expectEqualStrings(child_id, delivery.source_id);
            try std.testing.expectEqualStrings(root_id, delivery.target_id);
            try std.testing.expect(delivery.work_id != null);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);

    var cancel = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .cancel,
    } });
    defer cancel.deinit(alloc);
    const cancelled = try host.execute(alloc, &cancel, testOptions(root_id, "cancel-milestone"));
    defer alloc.free(cancelled);
    try std.testing.expect(std.mem.find(u8, cancelled, "\"ok\":true") != null);
    try std.testing.expectEqual(execution.ChildResult.cancelled, try host.owner.join(child_id));
}

test "tool host create replay returns the original child without another session" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replayed-worker",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var create_options = testOptions(root_id, "same-create");
    create_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        create_options.invocation_id,
        .model,
    );
    const first = try host.execute(alloc, &create, create_options);
    defer alloc.free(first);
    const replay = try host.execute(alloc, &create, create_options);
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(first, replay);
    const child_id = try resultChildIdAlloc(alloc, first);
    defer alloc.free(child_id);
    const operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        create_options.invocation_id,
        .model,
        create_options.identity_epoch,
    );
    defer alloc.free(operation_id);
    const legacy_create_store_fingerprint =
        domain.legacyImplicitAutoCreateRequestFingerprint(.{
            .command = create,
            .actor_id = root_id,
            .target_id = "",
            .effective_parent_id = root_id,
        }) orelse return error.TestUnexpectedResult;
    const legacy_control_fingerprint =
        domain.legacyImplicitAutoCreateRequestFingerprint(.{
            .command = create,
            .actor_id = root_id,
            .target_id = child_id,
            .effective_parent_id = root_id,
        }) orelse return error.TestUnexpectedResult;

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        var found = false;
        for (record.entries) |*entry| {
            if (!std.mem.eql(u8, entry.operation_id, operation_id)) continue;
            entry.request_fingerprint = legacy_create_store_fingerprint;
            found = true;
            break;
        }
        try std.testing.expect(found);
        try store.save(alloc, record);
    }
    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        record.configuration.permission_mode = .auto;
        var found = false;
        for (record.operations) |*operation| {
            if (!std.mem.eql(u8, operation.id, operation_id)) continue;
            operation.request_fingerprint = legacy_control_fingerprint;
            found = true;
            break;
        }
        try std.testing.expect(found);
        try store.save(alloc, record);
    }

    const restarted_host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer restarted_host.deinit();
    var restarted_request = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replayed-worker",
        .mode = .persistent,
    } });
    defer restarted_request.deinit(alloc);
    const durable_replay = try restarted_host.execute(
        alloc,
        &restarted_request,
        create_options,
    );
    defer alloc.free(durable_replay);
    try std.testing.expectEqualStrings(first, durable_replay);
    {
        var capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        try std.testing.expectEqual(
            types.PermissionMode.auto,
            record.configuration.permission_mode,
        );
    }

    var explicit_yolo = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replayed-worker",
        .mode = .persistent,
        .permission_mode = .yolo,
    } });
    defer explicit_yolo.deinit(alloc);
    const explicit_conflict = try restarted_host.execute(
        alloc,
        &explicit_yolo,
        create_options,
    );
    defer alloc.free(explicit_conflict);
    try std.testing.expect(
        std.mem.find(u8, explicit_conflict, "operation_conflict") != null,
    );

    var changed_command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "different-worker",
        .mode = .persistent,
    } });
    defer changed_command.deinit(alloc);
    const command_conflict = try host.execute(
        alloc,
        &changed_command,
        create_options,
    );
    defer alloc.free(command_conflict);
    try std.testing.expect(std.mem.find(u8, command_conflict, "operation_conflict") != null);

    var changed_defaults = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replayed-worker",
        .mode = .persistent,
    } });
    defer changed_defaults.deinit(alloc);
    var alternate_options = create_options;
    alternate_options.defaults.model = "different/model";
    const defaults_conflict = try host.execute(alloc, &changed_defaults, alternate_options);
    defer alloc.free(defaults_conflict);
    try std.testing.expect(std.mem.find(u8, defaults_conflict, "operation_conflict") != null);

    var changed_caller = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replayed-worker",
        .mode = .persistent,
    } });
    defer changed_caller.deinit(alloc);
    const caller_conflict = try host.execute(
        alloc,
        &changed_caller,
        .{
            .caller_id = child_id,
            .invocation_id = create_options.invocation_id,
            .defaults = create_options.defaults,
            .max_result_bytes = create_options.max_result_bytes,
            .timestamp_ms = create_options.timestamp_ms,
            .identity_epoch = create_options.identity_epoch,
        },
    );
    defer alloc.free(caller_conflict);
    try std.testing.expect(std.mem.find(u8, caller_conflict, "operation_conflict") != null);

    var changed_branch = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
    } });
    defer changed_branch.deinit(alloc);
    const branch_conflict = try host.execute(
        alloc,
        &changed_branch,
        create_options,
    );
    defer alloc.free(branch_conflict);
    try std.testing.expect(std.mem.find(u8, branch_conflict, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, branch_conflict, "\"status\":\"idle\"") != null);

    var child_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (child_ids.items) |id| alloc.free(id);
        child_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 2), child_ids.items.len);
}

test "evicted create retry expires before allocating another child" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "evicted-create",
        .mode = .persistent,
    } });
    defer command.deinit(alloc);
    var options = testOptions(root_id, "evicted-create");
    options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        options.invocation_id,
        .model,
    );
    const first = try host.execute(alloc, &command, options);
    defer alloc.free(first);
    try std.testing.expect(std.mem.find(u8, first, "\"ok\":true") != null);

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        for (record.entries) |entry| {
            alloc.free(entry.operation_id);
            alloc.free(entry.child_id);
        }
        alloc.free(record.entries);
        record.entries = try alloc.alloc(create_store.Entry, 0);
        record.model_replay_floor = options.identity_epoch +| 1;
        try store.save(alloc, record);
    }
    var before = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (before.items) |id| alloc.free(id);
        before.deinit(alloc);
    }
    const expired = try host.execute(alloc, &command, options);
    defer alloc.free(expired);
    try std.testing.expect(
        std.mem.find(u8, expired, "\"error_code\":\"operation_replay_expired\"") != null,
    );
    var after = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (after.items) |id| alloc.free(id);
        after.deinit(alloc);
    }
    try std.testing.expectEqual(before.items.len, after.items.len);
}

const ConcurrentCreate = struct {
    host: *Runtime,
    root_id: []const u8,
    identity_epoch: u64,
    encoded: ?[]u8 = null,
    failed: bool = false,

    fn run(self: *ConcurrentCreate) void {
        const alloc = std.heap.c_allocator;
        var command = domain.validateCommand(alloc, .{ .create = .{
            .name = "concurrent-worker",
            .mode = .persistent,
        } }) catch {
            self.failed = true;
            return;
        };
        defer command.deinit(alloc);
        var options = testOptions(self.root_id, "concurrent-create");
        options.identity_epoch = self.identity_epoch;
        self.encoded = self.host.execute(alloc, &command, options) catch {
            self.failed = true;
            return;
        };
    }
};

const CreateSyncFailure = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *CreateSyncFailure = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

const FailFirstTwoDirSyncs = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailFirstTwoDirSyncs = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls <= 2) return error.InjectedDirSyncFailure;
    }
};

test "identity issuance reconciles commit-indeterminate ownership" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var sync_failure = CreateSyncFailure{};
    host.manager.options.child_store = .{ .replace_ops = .{
        .ctx = &sync_failure,
        .sync_dir = CreateSyncFailure.syncDir,
    } };
    const epoch = try host.issueOperationIdentity(
        alloc,
        "indeterminate-identity",
        .human,
    );
    try std.testing.expectEqual(
        epoch,
        try host.issueOperationIdentity(
            alloc,
            "indeterminate-identity",
            .human,
        ),
    );
    const operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        "indeterminate-identity",
        .human,
        epoch,
    );
    defer alloc.free(operation_id);
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        operation_id,
    ));
    try std.testing.expect(sync_failure.calls >= 1);
}

test "allocation abort and finalization indeterminacy preserve exact ownership" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "finalization-fixture",
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var created = try host.executeHumanCommand(
        alloc,
        &create,
        testHumanOptions("create-finalization-fixture"),
    );
    defer created.deinit(alloc);
    try std.testing.expect(created == .receipt);
    const child_id = try alloc.dupe(u8, created.receipt.target_id);
    defer alloc.free(child_id);

    var allocation_command = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "after allocation retry",
    } });
    defer allocation_command.deinit(alloc);
    var allocation_options = testHumanOptions("allocation-owned-operation");
    allocation_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        allocation_options.invocation_id,
        .human,
    );
    const allocation_operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        allocation_options.invocation_id,
        .human,
        allocation_options.identity_epoch,
    );
    defer alloc.free(allocation_operation_id);
    var failing_alloc = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        host.executeHumanCommand(
            failing_alloc.allocator(),
            &allocation_command,
            allocation_options,
        ),
    );
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        allocation_operation_id,
    ));
    var allocation_retry = try host.executeHumanCommand(
        alloc,
        &allocation_command,
        allocation_options,
    );
    defer allocation_retry.deinit(alloc);
    try std.testing.expect(allocation_retry == .receipt);
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        allocation_operation_id,
    ));

    var indeterminate_command = try domain.validateCommand(alloc, .{ .configure = .{
        .id = child_id,
        .name = "committed once",
    } });
    defer indeterminate_command.deinit(alloc);
    var indeterminate_options = testHumanOptions("indeterminate-finalization");
    indeterminate_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        indeterminate_options.invocation_id,
        .human,
    );
    const indeterminate_operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        indeterminate_options.invocation_id,
        .human,
        indeterminate_options.identity_epoch,
    );
    defer alloc.free(indeterminate_operation_id);
    var sync_failure = FailFirstTwoDirSyncs{};
    host.manager.options.child_store = .{ .replace_ops = .{
        .ctx = &sync_failure,
        .sync_dir = FailFirstTwoDirSyncs.syncDir,
    } };
    var indeterminate = try host.executeHumanCommand(
        alloc,
        &indeterminate_command,
        indeterminate_options,
    );
    defer indeterminate.deinit(alloc);
    try std.testing.expect(indeterminate == .failure);
    try std.testing.expectEqual(
        manager_mod.FailureCode.control_commit_indeterminate,
        indeterminate.failure.code,
    );
    try std.testing.expect(indeterminate.failure.retryable);
    try std.testing.expect(try host.operationIdentityOutstanding(
        alloc,
        indeterminate_operation_id,
    ));

    host.manager.options.child_store = .{};
    var replay = try host.executeHumanCommand(
        alloc,
        &indeterminate_command,
        indeterminate_options,
    );
    defer replay.deinit(alloc);
    try std.testing.expect(replay == .receipt);
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        indeterminate_operation_id,
    ));
    var child_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer child_capability.deinit();
    const child_store = control_store.Store{
        .capability = &child_capability,
        .expected_child_id = child_id,
    };
    var durable = try child_store.load(alloc);
    defer durable.deinit(alloc);
    try std.testing.expectEqualStrings("committed once", durable.configuration.name);

    const aborted_epoch = try host.issueOperationIdentity(
        alloc,
        "production-abort",
        .human,
    );
    const aborted_operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        "production-abort",
        .human,
        aborted_epoch,
    );
    defer alloc.free(aborted_operation_id);
    try host.abortOperationIdentity(
        "production-abort",
        .human,
        aborted_epoch,
    );
    try std.testing.expect(!try host.operationIdentityOutstanding(
        alloc,
        aborted_operation_id,
    ));
    var aborted_options = testHumanOptions("production-abort");
    aborted_options.identity_epoch = aborted_epoch;
    var retired_close = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = "01J00000000000000000009999",
        .action = .close,
    } });
    defer retired_close.deinit(alloc);
    var expired = try host.executeHumanCommand(
        alloc,
        &retired_close,
        aborted_options,
    );
    defer expired.deinit(alloc);
    try std.testing.expect(expired == .failure);
    try std.testing.expectEqual(
        manager_mod.FailureCode.operation_replay_expired,
        expired.failure.code,
    );
}

test "create reconciles a commit-indeterminate durable reservation" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var sync_failure = CreateSyncFailure{};
    host.manager.options.child_store = .{ .replace_ops = .{
        .ctx = &sync_failure,
        .sync_dir = CreateSyncFailure.syncDir,
    } };
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "indeterminate-worker",
        .mode = .persistent,
    } });
    defer command.deinit(alloc);
    var create_options = testOptions(root_id, "indeterminate-create");
    create_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        create_options.invocation_id,
        .model,
    );
    const first = try host.execute(alloc, &command, create_options);
    defer alloc.free(first);
    try std.testing.expect(std.mem.find(u8, first, "\"ok\":true") != null);
    try std.testing.expect(sync_failure.calls >= 2);
    const replay = try host.execute(alloc, &command, create_options);
    defer alloc.free(replay);
    try std.testing.expectEqualStrings(first, replay);
    var session_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (session_ids.items) |id| alloc.free(id);
        session_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 2), session_ids.items.len);
}

test "concurrent duplicate create calls share one durable reservation" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const first_host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer first_host.deinit();
    const second_host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer second_host.deinit();
    first_host.recovery_state.store(.complete, .release);
    second_host.recovery_state.store(.complete, .release);
    const identity_epoch = try first_host.issueOperationIdentity(
        alloc,
        "concurrent-create",
        .model,
    );
    var first = ConcurrentCreate{
        .host = first_host,
        .root_id = root_id,
        .identity_epoch = identity_epoch,
    };
    var second = ConcurrentCreate{
        .host = second_host,
        .root_id = root_id,
        .identity_epoch = identity_epoch,
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentCreate.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentCreate.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!first.failed and !second.failed);
    defer std.heap.c_allocator.free(first.encoded.?);
    defer std.heap.c_allocator.free(second.encoded.?);
    try std.testing.expectEqualStrings(first.encoded.?, second.encoded.?);
    var session_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (session_ids.items) |id| alloc.free(id);
        session_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 2), session_ids.items.len);
}

test "nested children resolve the same current controlling authority" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var initial_rules = [_]types.PermissionRule{.{
        .permission = @constCast("read"),
        .pattern = @constCast("*"),
        .action = .allow,
    }};
    var initial_grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("read_file"),
        .target_path = @constCast("README.md"),
    }};
    var test_authority = TestAuthority{
        .root_id = root_id,
        .tools = &.{ "read_file", "subagent" },
        .integrations = &.{"mcp_old"},
        .rules = .{ .rules = &initial_rules },
        .grants = &initial_grants,
    };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var parent_command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "parent-child",
        .mode = .persistent,
        .permission_mode = .auto,
    } });
    defer parent_command.deinit(alloc);
    const parent_result = try host.execute(
        alloc,
        &parent_command,
        testOptions(root_id, "create-parent-child"),
    );
    defer alloc.free(parent_result);
    const parent_id = try resultChildIdAlloc(alloc, parent_result);
    defer alloc.free(parent_id);
    var nested_command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "nested-child",
        .mode = .persistent,
        .permission_mode = .auto,
    } });
    defer nested_command.deinit(alloc);
    const nested_result = try host.execute(
        alloc,
        &nested_command,
        testOptions(parent_id, "create-nested-child"),
    );
    defer alloc.free(nested_result);
    const nested_id = try resultChildIdAlloc(alloc, nested_result);
    defer alloc.free(nested_id);

    var initial_parent = try host.authority_resolver.resolve(alloc, parent_id);
    defer initial_parent.deinit(alloc);
    var initial_nested = try host.authority_resolver.resolve(alloc, nested_id);
    defer initial_nested.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.auto, initial_nested.permission_mode);
    try std.testing.expectEqualStrings("mcp_old", initial_nested.integrations[0]);

    var next_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("src/**"),
        .action = .deny,
    }};
    var next_grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("write_file"),
        .target_path = @constCast("src/new.zig"),
    }};
    test_authority.tools = &.{ "write_file", "subagent" };
    test_authority.integrations = &.{"mcp_new"};
    test_authority.rules = .{ .rules = &next_rules };
    test_authority.grants = &next_grants;
    var current_parent = try host.authority_resolver.resolve(alloc, parent_id);
    defer current_parent.deinit(alloc);
    var current_nested = try host.authority_resolver.resolve(alloc, nested_id);
    defer current_nested.deinit(alloc);
    for ([_]authority.Snapshot{ current_parent, current_nested }) |snapshot| {
        try std.testing.expectEqual(@as(usize, 2), snapshot.tools.len);
        try std.testing.expectEqualStrings("write_file", snapshot.tools[0]);
        try std.testing.expectEqual(@as(usize, 1), snapshot.integrations.len);
        try std.testing.expectEqualStrings("mcp_new", snapshot.integrations[0]);
        try std.testing.expectEqual(@as(usize, 1), snapshot.rules.rules.len);
        try std.testing.expectEqualStrings("src/**", snapshot.rules.rules[0].pattern);
        try std.testing.expectEqual(@as(usize, 1), snapshot.grants.len);
        try std.testing.expectEqualStrings("src/new.zig", snapshot.grants[0].target_path);
    }
    try std.testing.expect(initial_parent.generation != current_parent.generation);
    try std.testing.expect(initial_nested.generation != current_nested.generation);
}

const CountingChild = struct {
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn run(
        raw: ?*anyopaque,
        turn: *execution.TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        _: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *CountingChild = @ptrCast(@alignCast(raw.?));
        const history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "completed",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        turn.commit(message.id, history_turn, 1, 1, io_mod.milliTimestamp()) catch
            return error.ProviderFailed;
        _ = self.completed.fetchAdd(1, .seq_cst);
        return .completed;
    }

    fn waitFor(self: *CountingChild, expected: usize) !void {
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (self.completed.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (self.completed.load(.seq_cst) != expected) {
            return error.TestUnexpectedResult;
        }
    }
};

const ReleasableLiveChild = struct {
    entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        turn: *execution.TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *ReleasableLiveChild = @ptrCast(@alignCast(raw.?));
        turn.appendLiveText(message.content);
        turn.toolActivityRecorder().record(
            "call-live",
            "read_file",
            .started,
        ) catch return error.ProviderFailed;
        _ = self.entered.fetchAdd(1, .seq_cst);
        while (!self.release.load(.seq_cst) and !cancel.load(.seq_cst)) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        const history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "completed",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        turn.commit(message.id, history_turn, 1, 1, io_mod.milliTimestamp()) catch
            return error.ProviderFailed;
        _ = self.completed.fetchAdd(1, .seq_cst);
        return .completed;
    }

    fn waitFor(
        self: *ReleasableLiveChild,
        field: *std.atomic.Value(usize),
        expected: usize,
    ) !void {
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (field.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (field.load(.seq_cst) != expected) return error.TestUnexpectedResult;
        _ = self;
    }
};

const HeldCancellationChild = struct {
    entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        _: *execution.TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *HeldCancellationChild = @ptrCast(@alignCast(raw.?));
        _ = self.entered.fetchAdd(1, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        return error.ProviderFailed;
    }

    fn waitFor(self: *HeldCancellationChild, expected: usize) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (self.entered.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.entered.load(.seq_cst) != expected) {
            return error.TestUnexpectedResult;
        }
    }
};

const ReleaseAfterWaiterRegistration = struct {
    owner: *execution.Owner,
    runner: *ReleasableLiveChild,
    observed_registration: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ReleaseAfterWaiterRegistration) void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (io_mod.milliTimestamp() < deadline) {
            self.owner.mutex.lockUncancelable(io_mod.getIo());
            const registered = self.owner.child_waiters.items.len != 0;
            self.owner.mutex.unlock(io_mod.getIo());
            if (registered) {
                self.observed_registration.store(true, .seq_cst);
                self.runner.release.store(true, .seq_cst);
                return;
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
    }
};

const ConcurrentInspectWait = struct {
    host: *Runtime,
    root_id: []const u8,
    child_id: []const u8,
    encoded: ?[]u8 = null,
    failure: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ConcurrentInspectWait) void {
        const alloc = std.heap.c_allocator;
        var inspect = domain.validateCommand(alloc, .{ .inspect = .{
            .id = self.child_id,
            .sections = &.{ .status, .messages },
            .wait = .{
                .until = .settled,
                .timeout_ms = domain.max_inspect_wait_ms,
            },
        } }) catch |err| {
            self.failure = err;
            self.completed.store(true, .seq_cst);
            return;
        };
        defer inspect.deinit(alloc);
        self.encoded = self.host.execute(
            alloc,
            &inspect,
            testOptions(self.root_id, "concurrent-inspect-wait"),
        ) catch |err| {
            self.failure = err;
            self.completed.store(true, .seq_cst);
            return;
        };
        self.completed.store(true, .seq_cst);
    }
};

fn waitForRegisteredChildWaiter(owner: *execution.Owner) !void {
    const deadline = io_mod.milliTimestamp() + 15_000;
    while (io_mod.milliTimestamp() < deadline) {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const registered = owner.child_waiters.items.len != 0;
        owner.mutex.unlock(io_mod.getIo());
        if (registered) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}

test "inspect wait subscribes before reading and returns the settled child" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = ReleasableLiveChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = ReleasableLiveChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "waited-worker",
        .mode = .persistent,
        .prompt = "complete after the parent subscribes",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-waited-worker"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(&runner.entered, 1);

    var release = ReleaseAfterWaiterRegistration{
        .owner = &host.owner,
        .runner = &runner,
    };
    const release_thread = try std.Thread.spawn(
        .{},
        ReleaseAfterWaiterRegistration.run,
        .{&release},
    );
    defer release_thread.join();

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{ .status, .messages },
        .wait = .{
            .until = .settled,
            .timeout_ms = 2_000,
        },
    } });
    defer inspect.deinit(alloc);
    const inspected = try host.execute(
        alloc,
        &inspect,
        testOptions(root_id, "wait-for-worker"),
    );
    defer alloc.free(inspected);

    try std.testing.expect(release.observed_registration.load(.seq_cst));
    try runner.waitFor(&runner.completed, 1);
    try std.testing.expect(std.mem.find(u8, inspected, "\"status\":\"idle\"") != null);
    try std.testing.expect(std.mem.find(u8, inspected, "wait_timed_out") == null);
    try std.testing.expect(std.mem.find(u8, inspected, "complete after the parent subscribes") != null);
}

test "inspect wait timeout returns the latest authoritative inspection" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = ReleasableLiveChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = ReleasableLiveChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "timeout-worker",
        .mode = .persistent,
        .prompt = "remain active past the bounded wait",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-timeout-worker"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(&runner.entered, 1);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = child_id,
        .sections = &.{.status},
        .wait = .{
            .until = .settled,
            .timeout_ms = 5,
        },
    } });
    defer inspect.deinit(alloc);
    const inspected = try host.execute(
        alloc,
        &inspect,
        testOptions(root_id, "timeout-wait-for-worker"),
    );
    defer alloc.free(inspected);
    try std.testing.expect(std.mem.find(
        u8,
        inspected,
        "\"status\":\"wait_timed_out\"",
    ) != null);
    try std.testing.expect(std.mem.find(u8, inspected, "\"status\":\"running\"") != null);

    runner.release.store(true, .seq_cst);
    try runner.waitFor(&runner.completed, 1);
}

test "inspect wait rechecks durable relationship authority after every wait" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = ReleasableLiveChild{};
    defer runner.release.store(true, .seq_cst);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        std.heap.c_allocator,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = ReleasableLiveChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "detached-while-waiting",
        .mode = .persistent,
        .prompt = "private child context",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(
        alloc,
        &create,
        testOptions(root_id, "create-detached-waiter"),
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(&runner.entered, 1);

    var waiting = ConcurrentInspectWait{
        .host = host,
        .root_id = root_id,
        .child_id = child_id,
    };
    const waiting_thread = try std.Thread.spawn(
        .{},
        ConcurrentInspectWait.run,
        .{&waiting},
    );
    var waiting_thread_joined = false;
    defer if (!waiting_thread_joined) waiting_thread.join();
    try waitForRegisteredChildWaiter(&host.owner);

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    {
        var lock = try control.acquireLock();
        defer lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        if (record.parent_id) |parent_id| alloc.free(parent_id);
        record.parent_id = null;
        try control.save(alloc, record);
    }
    host.owner.mutex.lockUncancelable(io_mod.getIo());
    for (host.owner.child_waiters.items) |registered| {
        if (!std.mem.eql(u8, registered.child_id, child_id)) continue;
        registered.event.set(io_mod.getIo());
        break;
    }
    host.owner.mutex.unlock(io_mod.getIo());

    const completion_deadline = io_mod.milliTimestamp() + 15_000;
    while (!waiting.completed.load(.seq_cst) and
        io_mod.milliTimestamp() < completion_deadline)
    {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(waiting.completed.load(.seq_cst));
    waiting_thread.join();
    waiting_thread_joined = true;
    try std.testing.expect(waiting.failure == null);
    const encoded = waiting.encoded orelse return error.TestUnexpectedResult;
    defer std.heap.c_allocator.free(encoded);
    try std.testing.expect(std.mem.find(
        u8,
        encoded,
        "\"error_code\":\"child_unavailable\"",
    ) != null);
    try std.testing.expect(std.mem.find(u8, encoded, "private child context") == null);

    runner.release.store(true, .seq_cst);
    try runner.waitFor(&runner.completed, 1);
}

test "typed message send queues a busy child without steering active work" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = ReleasableLiveChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = ReleasableLiveChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "busy-worker",
        .mode = .persistent,
        .prompt = "first active turn",
    } });
    defer create.deinit(alloc);
    var create_options = testOptions(root_id, "create-busy-worker");
    create_options.root_user_intent_context =
        "current_request: create the busy worker\n";
    create_options.root_user_messages = &.{
        "Do not modify files.",
        "Create the busy worker for inspection.",
    };
    create_options.root_user_evidence_complete = true;
    const created = try host.execute(
        alloc,
        &create,
        create_options,
    );
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(&runner.entered, 1);

    var live = (try host.owner.snapshotLivePresentation(alloc, child_id)).?;
    defer live.deinit(alloc);
    try std.testing.expectEqualStrings("first active turn", live.text);
    try std.testing.expectEqual(@as(usize, 1), live.tools.len);
    try std.testing.expectEqualStrings("read_file", live.tools[0].tool_name);

    var send_options = MessageSendOptions{
        .caller_id = root_id,
        .invocation_id = "human-send-retry-stable",
        .child_id = child_id,
        .content = "second queued turn",
        .timestamp_ms = 20,
    };
    send_options.identity_epoch = try host.issueOperationIdentity(
        alloc,
        send_options.invocation_id,
        .human,
    );
    var sent = try host.sendMessage(alloc, send_options);
    defer sent.deinit(alloc);
    try std.testing.expect(sent == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.message_queued, sent.receipt.code);
    const receipt_id = try alloc.dupe(u8, sent.receipt.id);
    defer alloc.free(receipt_id);

    var replay = try host.sendMessage(alloc, send_options);
    defer replay.deinit(alloc);
    try std.testing.expect(replay == .receipt);
    try std.testing.expectEqualStrings(receipt_id, replay.receipt.id);
    try std.testing.expectEqual(sent.receipt.event_sequence, replay.receipt.event_sequence);

    var conflict_options = send_options;
    conflict_options.content = "different retry text";
    var conflict = try host.sendMessage(alloc, conflict_options);
    defer conflict.deinit(alloc);
    try std.testing.expect(conflict == .failure);
    try std.testing.expectEqual(manager_mod.FailureCode.operation_conflict, conflict.failure.code);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var record = try control.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), record.queue.len);
    try std.testing.expectEqual(domain.QueueStatus.running, record.queue[0].status);
    try std.testing.expectEqual(domain.QueueStatus.pending, record.queue[1].status);
    try std.testing.expectEqualStrings(
        "current_request: create the busy worker\n",
        record.queue[0].root_user_intent_context,
    );
    try std.testing.expect(record.queue[0].root_user_evidence_complete);
    try std.testing.expectEqual(@as(usize, 2), record.queue[0].root_user_messages.len);
    try std.testing.expectEqualStrings(
        "Do not modify files.",
        record.queue[0].root_user_messages[0],
    );
    try std.testing.expectEqualStrings(root_id, record.queue[1].source_id);
    try std.testing.expectEqualStrings("second queued turn", record.queue[1].content);
    try std.testing.expectEqualStrings(
        "current_request: second queued turn\n",
        record.queue[1].root_user_intent_context,
    );
    try std.testing.expect(record.queue[1].root_user_evidence_complete);
    try std.testing.expectEqual(@as(usize, 1), record.queue[1].root_user_messages.len);
    try std.testing.expectEqualStrings(
        "second queued turn",
        record.queue[1].root_user_messages[0],
    );
    try std.testing.expect(std.mem.find(u8, record.queue[1].content, "source") == null);
    try std.testing.expectEqual(@as(usize, 1), runner.entered.load(.seq_cst));

    runner.release.store(true, .seq_cst);
    try runner.waitFor(&runner.completed, 2);
    const live_deadline = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < live_deadline) {
        var maybe_live = try host.owner.snapshotLivePresentation(alloc, child_id);
        if (maybe_live == null) break;
        maybe_live.?.deinit(alloc);
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect((try host.owner.snapshotLivePresentation(alloc, child_id)) == null);

    var loaded = try env.store.loadReadOnly(alloc, child_id);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.history.len);
    try std.testing.expectEqualStrings("first active turn", loaded.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("second queued turn", loaded.history[1].assistant.user.text);
    try std.testing.expectEqualStrings(receipt_id, session.historyTurnWorkId(loaded.history[1]).?);
}

test "tool host persistent child executes a message after returning idle" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var runner = CountingChild{};
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{ .context = &runner, .run_fn = CountingChild.run },
    );
    defer host.deinit();

    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "persistent-worker",
        .mode = .persistent,
        .prompt = "first turn",
    } });
    defer create.deinit(alloc);
    const created = try host.execute(alloc, &create, testOptions(root_id, "create-persistent"));
    defer alloc.free(created);
    const child_id = try resultChildIdAlloc(alloc, created);
    defer alloc.free(child_id);
    try runner.waitFor(1);
    const idle_deadline = io_mod.milliTimestamp() + 15_000;
    while (io_mod.milliTimestamp() < idle_deadline) {
        var maybe_live = try host.owner.snapshotLivePresentation(alloc, child_id);
        if (maybe_live == null) break;
        maybe_live.?.deinit(alloc);
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect((try host.owner.snapshotLivePresentation(alloc, child_id)) == null);

    var send = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = child_id,
        .content = "second turn",
    } } });
    defer send.deinit(alloc);
    const sent = try host.execute(alloc, &send, testOptions(root_id, "send-second"));
    defer alloc.free(sent);
    try std.testing.expect(std.mem.find(u8, sent, "\"ok\":true") != null);
    try runner.waitFor(2);

    for (3..18) |turn_index| {
        const content = try std.fmt.allocPrint(alloc, "turn {d}", .{turn_index});
        defer alloc.free(content);
        const invocation_id = try std.fmt.allocPrint(alloc, "send-{d}", .{turn_index});
        defer alloc.free(invocation_id);
        var repeated = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
            .id = child_id,
            .content = content,
        } } });
        defer repeated.deinit(alloc);
        const queued = try host.execute(
            alloc,
            &repeated,
            testOptions(root_id, invocation_id),
        );
        defer alloc.free(queued);
        try std.testing.expect(std.mem.find(u8, queued, "\"ok\":true") != null);
        try runner.waitFor(turn_index);
    }

    var loaded = try env.store.loadReadOnly(alloc, child_id);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 17), loaded.history.len);
    try std.testing.expectEqualStrings("second turn", loaded.history[1].assistant.user.text);
    try std.testing.expectEqualStrings("turn 17", loaded.history[16].assistant.user.text);
}

test "child beyond the first tree page can message its direct parent only" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = TestAuthority{ .root_id = root_id };
    const host = try Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();

    var child_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (child_ids.items) |id| alloc.free(id);
        child_ids.deinit(alloc);
    }
    for (0..101) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(
            &child_buffer,
            "sibling-{d:0>3}",
            .{index},
        );
        try env.createSession(alloc, child_id);
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try std.fmt.bufPrint(
            &operation_buffer,
            "create-sibling-{d:0>3}",
            .{index},
        );
        var create = try domain.validateCommand(alloc, .{ .create = .{
            .name = "sibling",
            .mode = .persistent,
        } });
        defer create.deinit(alloc);
        var created = try host.manager.execute(alloc, create, .{
            .actor_id = root_id,
            .operation_id = operation_id,
            .created_child_id = child_id,
            .timestamp_ms = @intCast(index + 1),
        });
        defer created.deinit(alloc);
        try std.testing.expect(created == .receipt);
        try child_ids.append(alloc, try alloc.dupe(u8, child_id));
    }

    var first_page = try host.manager.snapshot(alloc, .{
        .root_id = root_id,
        .limit = domain.max_page_limit,
    });
    defer first_page.deinit(alloc);
    const snapshot = first_page.snapshot;
    try std.testing.expectEqual(domain.max_page_limit, snapshot.nodes.len);
    var caller_id: ?[]const u8 = null;
    for (child_ids.items) |child_id| {
        var present = false;
        for (snapshot.nodes) |node| {
            if (std.mem.eql(u8, child_id, node.child_id)) present = true;
        }
        if (!present) {
            caller_id = child_id;
            break;
        }
    }
    const caller = caller_id orelse return error.TestUnexpectedResult;
    const unrelated = if (std.mem.eql(u8, child_ids.items[0], caller))
        child_ids.items[1]
    else
        child_ids.items[0];

    var send_parent = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = root_id,
        .content = "parent update",
    } } });
    defer send_parent.deinit(alloc);
    const sent = try host.execute(
        alloc,
        &send_parent,
        testOptions(caller, "message-parent"),
    );
    defer alloc.free(sent);
    try std.testing.expect(std.mem.find(u8, sent, "\"ok\":true") != null);

    var caller_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        caller,
        .{},
    );
    defer caller_capability.deinit();
    const communications = communication_store.Store{
        .capability = &caller_capability,
        .expected_session_id = caller,
    };
    var ledger = try communications.load(alloc);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), ledger.deliveries.len);
    try std.testing.expectEqualStrings(root_id, ledger.deliveries[0].target_id);
    try std.testing.expectEqualStrings(
        "parent update",
        ledger.deliveries[0].payload.message,
    );

    var unrelated_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        unrelated,
        .{},
    );
    defer unrelated_capability.deinit();
    const unrelated_store = control_store.Store{
        .capability = &unrelated_capability,
        .expected_child_id = unrelated,
    };
    var before = try unrelated_store.load(alloc);
    defer before.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), before.queue.len);

    var send_unrelated = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = unrelated,
        .content = "not authorized",
    } } });
    defer send_unrelated.deinit(alloc);
    const rejected = try host.execute(
        alloc,
        &send_unrelated,
        testOptions(caller, "message-unrelated"),
    );
    defer alloc.free(rejected);
    try std.testing.expect(std.mem.find(u8, rejected, "child_unavailable") != null);
    var after = try unrelated_store.load(alloc);
    defer after.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), after.queue.len);
}
