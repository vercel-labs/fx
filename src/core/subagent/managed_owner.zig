const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_store = @import("../session/session_store.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const StartResult = enum { started, already_running };
pub const StartError = error{ OutOfMemory, OwnerClosed, ChildUnavailable, ThreadSpawnFailed };
pub const WaitError = error{ OutOfMemory, ChildUnavailable, StateUnavailable };
pub const CancelError = error{ChildUnavailable};

pub const Observation = struct {
    phase: child_state.Phase,
    outcome: ?child_state.Outcome = null,
    failure: ?types.ModelFailureDiagnostic = null,
};

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    worker: ?*worker_runtime.WorkerRuntime = null,
    route_refs: usize = 0,
    route_changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    completion: enum { running, published, unpublished } = .running,
    done: std.Io.Event = .unset,
};

pub const Owner = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    state_store: child_state.Store,
    services: execution.Services,
    authority_resolver: *authority.Resolver,
    approvals: *approval_registry.Registry,
    max_history_turns: usize = 8,
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    closed: bool = false,

    pub fn start(self: *Owner, child_id: []const u8) StartError!StartResult {
        while (true) {
            const finished = blk: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return error.OwnerClosed;
                for (self.slots.items, 0..) |slot, index| {
                    if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
                    if (slot.completion == .running) return .already_running;
                    break :blk self.slots.swapRemove(index);
                }
                const slot = try self.alloc.create(Slot);
                errdefer self.alloc.destroy(slot);
                slot.* = .{
                    .owner = self,
                    .child_id = try self.alloc.dupe(u8, child_id),
                };
                errdefer self.alloc.free(slot.child_id);
                try self.slots.append(self.alloc, slot);
                errdefer _ = self.slots.pop();
                slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch
                    return error.ThreadSpawnFailed;
                return .started;
            };
            destroySlot(self, finished);
        }
    }

    pub fn wait(
        self: *Owner,
        child_id: []const u8,
        duration: std.Io.Clock.Duration,
    ) WaitError!Observation {
        const slot = self.findSlot(child_id);
        if (slot) |active| {
            active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
                error.Timeout => return self.observe(child_id),
                error.Canceled => return self.observe(child_id),
            };
            try self.reapSlot(active);
        }
        return self.observe(child_id);
    }

    pub fn cancel(self: *Owner, child_id: []const u8) CancelError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            if (slot.completion != .running) return;
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestCancel();
            return;
        }
        return error.ChildUnavailable;
    }

    pub fn recoverInterrupted(self: *Owner) !void {
        var observed = try self.state_store.load(self.alloc);
        defer observed.deinit(self.alloc);
        if (observed.children.len == 0) return;

        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const generation = registry.generation;
        registry.interruptActive(self.alloc);
        if (registry.generation != generation) try self.state_store.save(self.alloc, registry);
    }

    pub fn deinit(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.slots.items) |slot| {
            slot.shutdown.store(true, .seq_cst);
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestShutdown();
        }
        self.mutex.unlock(io_mod.getIo());

        for (self.slots.items) |slot| {
            if (slot.thread) |thread| thread.join();
            self.alloc.free(slot.child_id);
            self.alloc.destroy(slot);
        }
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    fn findSlot(self: *Owner, child_id: []const u8) ?*Slot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot;
        }
        return null;
    }

    fn reapSlot(self: *Owner, slot: *Slot) error{StateUnavailable}!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var index: ?usize = null;
        for (self.slots.items, 0..) |candidate, candidate_index| {
            if (candidate == slot and candidate.completion != .running) {
                index = candidate_index;
                break;
            }
        }
        if (index == null) {
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        _ = self.slots.swapRemove(index.?);
        const unpublished = slot.completion == .unpublished;
        self.mutex.unlock(io_mod.getIo());
        destroySlot(self, slot);
        if (unpublished) return error.StateUnavailable;
    }

    fn observe(self: *Owner, child_id: []const u8) WaitError!Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch
            return error.StateUnavailable;
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StateUnavailable,
        };
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        return .{ .phase = child.phase, .outcome = child.last_outcome, .failure = child.last_failure };
    }

    fn phaseTransition(
        raw: *anyopaque,
        child_id: []const u8,
        work_id: []const u8,
        phase: child_state.Phase,
    ) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        child.phase = phase;
        registry.generation +|= 1;
        try self.state_store.save(self.alloc, registry);
    }

    fn finish(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        outcome: child_state.Outcome,
        failure: ?types.ModelFailureDiagnostic,
    ) bool {
        var lock = self.state_store.acquireLock(self.alloc) catch |err| {
            debugFailure(child_id, "state_lock", err);
            return false;
        };
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return false;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome, failure) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return false;
        };
        self.state_store.save(self.alloc, registry) catch |err| {
            debugFailure(child_id, "state_save", err);
            return false;
        };
        return true;
    }
};

fn destroySlot(owner: *Owner, slot: *Slot) void {
    if (slot.thread) |thread| thread.join();
    std.debug.assert(slot.route_refs == 0);
    owner.alloc.free(slot.child_id);
    owner.alloc.destroy(slot);
}

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    const outcome = runOne(slot);
    const published = owner.finish(slot.child_id, outcome.work_id, outcome.outcome, outcome.failure);
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.completion = if (published) .published else .unpublished;
    slot.done.set(io_mod.getIo());
    owner.mutex.unlock(io_mod.getIo());
    outcome.deinit(owner.alloc);
}

const OneOutcome = struct {
    work_id: []u8,
    outcome: child_state.Outcome,
    failure: ?types.ModelFailureDiagnostic = null,

    fn deinit(self: OneOutcome, alloc: Allocator) void {
        alloc.free(self.work_id);
    }
};

fn runOne(slot: *Slot) OneOutcome {
    const owner = slot.owner;
    var snapshot = loadRunSnapshot(owner, slot.child_id) catch |err| {
        debugFailure(slot.child_id, "run_snapshot", err);
        return fallbackOutcome(owner.alloc, "unknown", .failed);
    };
    defer snapshot.deinit(owner.alloc);
    const work_id = owner.alloc.dupe(u8, snapshot.active.id) catch
        return fallbackOutcome(owner.alloc, "unknown", .failed);

    var loaded = owner.sessions.resumeTargetForWrite(
        owner.alloc,
        .{ .id = slot.child_id },
        owner.sessions.workspace_root,
        .{},
    ) catch |err| return failedOutcome(work_id, "session_resume", err);
    defer {
        loaded.log.park();
        loaded.deinit(owner.alloc);
    }
    var turn = execution.TurnContext.init(
        owner.alloc,
        &loaded,
        owner.max_history_turns,
    ) catch |err| return failedOutcome(work_id, "turn_initialization", err);
    defer turn.deinit();
    turn.live_authority = owner.authority_resolver;
    turn.approval_registry = owner.approvals;
    turn.child_id = slot.child_id;
    turn.active_work_id = snapshot.active.id;
    turn.phase_context = owner;
    turn.phase_fn = Owner.phaseTransition;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = turn.workerRuntime();
    owner.mutex.unlock(io_mod.getIo());
    turn.approval_worker_route = workerRoute(slot);
    defer detachWorker(slot);

    var message = snapshot.active.queuedMessage(
        owner.alloc,
        owner.state_store.parent_id,
        snapshot.instructions,
    ) catch |err| return failedOutcome(work_id, "message_preparation", err);
    defer message.deinit(owner.alloc);
    const admission = owner.services.capture(owner.alloc, .{
        .child_id = slot.child_id,
        .parent_id = owner.state_store.parent_id,
        .source_id = owner.state_store.parent_id,
        .preferences = .{
            .provider = loaded.state.preferences.provider,
            .model = loaded.state.preferences.model,
            .effort = loaded.state.preferences.effort,
        },
    }) catch |err| return if (err == error.Cancelled) .{
        .work_id = work_id,
        .outcome = .cancelled,
    } else failedOutcome(work_id, "admission", err);
    var owned_admission = admission;
    defer owned_admission.deinit(owner.alloc);
    const result = owner.services.run(
        &turn,
        message,
        admission,
        &slot.cancel,
    ) catch |err| {
        const outcome: child_state.Outcome = if (slot.shutdown.load(.seq_cst))
            .interrupted
        else if (slot.cancel.load(.seq_cst) or err == error.Cancelled)
            .cancelled
        else
            .failed;
        return .{
            .work_id = work_id,
            .outcome = outcome,
            .failure = if (outcome == .failed)
                turn.failureDiagnostic() orelse execution.failureDiagnosticValue("agent_execution", @errorName(err))
            else
                null,
        };
    };
    if (slot.shutdown.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .interrupted,
    };
    if (slot.cancel.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .cancelled,
    };
    return .{
        .work_id = work_id,
        .outcome = switch (result) {
            .completed => .completed,
            .awaiting_approval, .paused => .interrupted,
        },
    };
}

fn workerRoute(slot: *Slot) approval_registry.WorkerRoute {
    return .{
        .context = slot,
        .submit_fn = submitWorkerApproval,
        .cancel_fn = cancelWorkerApproval,
        .pin_fn = pinWorkerRoute,
        .release_fn = releaseWorkerRoute,
    };
}

fn submitWorkerApproval(
    raw: *anyopaque,
    request_id: u64,
    response: permission_request.OwnedPermissionResponse,
    commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    const worker = slot.worker orelse {
        var owned = response;
        owned.deinit();
        return .no_pending;
    };
    return worker.submitPermissionResponseAfterCommit(
        request_id,
        response,
        commit,
    );
}

fn cancelWorkerApproval(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.worker) |worker| worker.cancelApprovalTurn();
}

fn pinWorkerRoute(raw: *anyopaque) bool {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.worker == null) return false;
    slot.route_refs += 1;
    return true;
}

fn releaseWorkerRoute(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    std.debug.assert(slot.route_refs > 0);
    slot.route_refs -= 1;
    if (slot.route_refs == 0) slot.route_changed.broadcast(io_mod.getIo());
}

fn detachWorker(slot: *Slot) void {
    const owner = slot.owner;
    _ = owner.approvals.invalidateChild(slot.child_id) catch |err|
        debugFailure(slot.child_id, "approval_invalidate", err);
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (slot.route_refs > 0) {
        slot.route_changed.waitUncancelable(io_mod.getIo(), &owner.mutex);
    }
    slot.worker = null;
    owner.mutex.unlock(io_mod.getIo());
}

const RunSnapshot = struct {
    active: child_state.ActiveWork,
    instructions: []u8,

    fn deinit(self: *RunSnapshot, alloc: Allocator) void {
        self.active.deinit(alloc);
        if (self.instructions.len > 0) alloc.free(self.instructions);
        self.* = undefined;
    }
};

fn loadRunSnapshot(owner: *Owner, child_id: []const u8) !RunSnapshot {
    var lock = try owner.state_store.acquireLock(owner.alloc);
    defer lock.release();
    var registry = try owner.state_store.load(owner.alloc);
    defer registry.deinit(owner.alloc);
    const child = registry.findById(child_id) orelse return error.ChildUnavailable;
    const active = child.active orelse return error.ChildUnavailable;
    const owned_active = try active.clone(owner.alloc);
    errdefer {
        var value = owned_active;
        value.deinit(owner.alloc);
    }
    const instructions: []u8 = if (child.instructions().len == 0)
        &.{}
    else
        try owner.alloc.dupe(u8, child.instructions());
    return .{
        .active = owned_active,
        .instructions = instructions,
    };
}

fn fallbackOutcome(alloc: Allocator, work_id: []const u8, outcome: child_state.Outcome) OneOutcome {
    return .{
        .work_id = alloc.dupe(u8, work_id) catch &.{},
        .outcome = outcome,
    };
}

fn failedOutcome(work_id: []u8, stage: []const u8, err: anyerror) OneOutcome {
    return .{
        .work_id = work_id,
        .outcome = .failed,
        .failure = execution.failureDiagnosticValue(stage, @errorName(err)),
    };
}

fn debugFailure(child_id: []const u8, stage: []const u8, err: anyerror) void {
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "managed child state update failed child_id={s} stage={s} err={s}",
        .{ child_id, stage, @errorName(err) },
    );
}

test "subagent failure to publish completion returns state unavailable instead of waiting" {
    const alloc = std.testing.allocator;
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = undefined,
        .state_store = undefined,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    const slot = try alloc.create(Slot);
    slot.* = .{
        .owner = &owner,
        .child_id = try alloc.dupe(u8, "child"),
        .completion = .unpublished,
    };
    try owner.slots.append(alloc, slot);
    slot.done.set(io_mod.getIo());
    try std.testing.expectError(error.StateUnavailable, owner.wait("child", .{
        .clock = .awake,
        .raw = .fromMilliseconds(1),
    }));
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
}

test "worker detach invalidates approval routes before worker deinit" {
    const alloc = std.testing.allocator;
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = undefined,
        .state_store = undefined,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    worker.worker_processing = true;
    worker.pending_permission_waiting = true;
    worker.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 9, .label = "review" },
        );
    var slot = Slot{
        .owner = &owner,
        .child_id = try alloc.dupe(u8, "child"),
        .worker = &worker,
    };
    defer alloc.free(slot.child_id);
    const route = workerRoute(&slot);
    try approvals.registerTool(
        "approval",
        "child",
        "root",
        "work",
        .{ .id = 9, .label = "review" },
        &.{},
        route,
        1,
    );

    detachWorker(&slot);
    try std.testing.expect(slot.worker == null);
    var pending = try approvals.firstPendingRequest(alloc, "root");
    defer if (pending) |*request| request.deinit(alloc);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.no_pending,
        try route.submit_fn(
            route.context,
            9,
            permission_request.OwnedPermissionResponse.init(alloc, .deny, null),
            null,
        ),
    );
}
