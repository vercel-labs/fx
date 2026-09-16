const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const live_metrics = @import("live_metrics.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
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
    metrics: live_metrics.Snapshot = .{},
};

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    metrics: live_metrics.LiveMetrics = .{},
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    worker: ?*worker_runtime.WorkerRuntime = null,
    work_id: ?[]const u8 = null,
    route_refs: usize = 0,
    waiters: usize = 0,
    route_changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    completion: union(enum) { running, published: Observation, unpublished } = .running,
    done: std.Io.Event = .unset,
};

pub const FeedbackResult = union(enum) {
    receipt: types.SteeringDelivery,
    waiting,
    unavailable,
    cancelled,
    conflict,
    capacity,
};

const Feedback = struct {
    child_id: []u8,
    operation_id: []u8,
    fingerprint: [32]u8,
    receipt: worker_runtime.SteeringReceipt = .{},
    reported: types.SteeringDelivery = .queued,

    fn create(alloc: Allocator, child_id: []const u8, operation_id: []const u8, fingerprint: [32]u8) !*Feedback {
        const item = try alloc.create(Feedback);
        errdefer alloc.destroy(item);
        const child = try alloc.dupe(u8, child_id);
        errdefer alloc.free(child);
        const operation = try alloc.dupe(u8, operation_id);
        item.* = .{ .child_id = child, .operation_id = operation, .fingerprint = fingerprint, .receipt = .{ .operation_id = operation } };
        return item;
    }

    fn deinit(self: *Feedback, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.operation_id);
        alloc.destroy(self);
    }
};

pub const FeedbackUpdate = struct {
    child_id: []const u8,
    operation_id: []const u8,
    delivery: types.SteeringDelivery,
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
    waiters_changed: std.Io.Condition = .init,
    slots: std.ArrayList(*Slot) = .empty,
    feedback: std.ArrayList(*Feedback) = .empty,
    closed: bool = false,

    fn feedbackReplayLocked(self: *Owner, operation_id: []const u8, fingerprint: [32]u8) ?FeedbackResult {
        for (self.feedback.items) |item| {
            if (!std.mem.eql(u8, item.operation_id, operation_id)) continue;
            return if (std.mem.eql(u8, &item.fingerprint, &fingerprint))
                .{ .receipt = item.receipt.state.load(.seq_cst) }
            else
                .conflict;
        }
        return null;
    }

    pub fn feedbackReplay(self: *Owner, operation_id: []const u8, fingerprint: [32]u8) ?FeedbackResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.feedbackReplayLocked(operation_id, fingerprint);
    }

    pub fn steer(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        operation_id: []const u8,
        fingerprint: [32]u8,
        text: []const u8,
    ) Allocator.Error!FeedbackResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return .unavailable;
        if (self.feedbackReplayLocked(operation_id, fingerprint)) |replay| return replay;
        var target: ?*Slot = null;
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) {
                target = slot;
                break;
            }
        }
        const slot = target orelse {
            const observation = self.observe(child_id) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .unavailable,
            };
            return if (observation.phase == .running or observation.phase == .awaiting_approval) .unavailable else .waiting;
        };
        if (slot.cancel.load(.seq_cst) or slot.shutdown.load(.seq_cst)) return .cancelled;
        if (slot.completion != .running) return if (slot.completion == .published) .waiting else .unavailable;
        const worker = slot.worker orelse return .waiting;
        if (!std.mem.eql(u8, slot.work_id orelse return .waiting, work_id)) return .waiting;
        if (self.feedback.items.len >= 64) return .capacity;
        try self.feedback.ensureUnusedCapacity(self.alloc, 1);
        const item = try Feedback.create(self.alloc, child_id, operation_id, fingerprint);
        var accepted = false;
        defer if (!accepted) item.deinit(self.alloc);
        const prompt = worker_runtime.QueuedPrompt{
            .prompt = try self.alloc.dupe(u8, text),
            .images = &.{},
            .model = &.{},
            .api_key = &.{},
            .permission_mode = .ask,
            .history = &.{},
            .grants = &.{},
            .steering_receipt = &item.receipt,
        };
        defer if (!accepted) {
            item.receipt.state.store(.not_applied, .seq_cst);
            worker_runtime.freeQueuedPrompt(self.alloc, prompt);
        };
        accepted = try worker.admitActiveSteering(self.alloc, prompt);
        if (!accepted) return .waiting;
        self.feedback.appendAssumeCapacity(item);
        debug_trace.eventf("subagent", "feedback_queued", .{}, "child_id={s} work_id={s} operation={s}", .{ child_id, work_id, operation_id });
        return .{ .receipt = .queued };
    }

    pub fn feedbackUpdates(self: *Owner, arena: Allocator) ![]FeedbackUpdate {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var updates: std.ArrayList(FeedbackUpdate) = .empty;
        for (self.feedback.items) |item| {
            const delivery = item.receipt.state.load(.seq_cst);
            if (delivery == item.reported) continue;
            try updates.append(arena, .{
                .child_id = try arena.dupe(u8, item.child_id),
                .operation_id = try arena.dupe(u8, item.operation_id),
                .delivery = delivery,
            });
        }
        return updates.toOwnedSlice(arena);
    }

    pub fn acknowledgeFeedback(self: *Owner, child_id: []const u8, operation_id: []const u8, delivery: types.SteeringDelivery) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.feedback.items) |item| {
            if (std.mem.eql(u8, item.child_id, child_id) and std.mem.eql(u8, item.operation_id, operation_id)) {
                if (item.receipt.state.load(.seq_cst) == delivery) item.reported = delivery;
                return;
            }
        }
    }

    pub fn hasRunningWork(self: *Owner) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (slot.completion == .running) return true;
        }
        return false;
    }

    pub fn hasRunningChild(self: *Owner, child_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot.completion == .running;
        }
        return false;
    }

    pub fn start(self: *Owner, child_id: []const u8) StartError!StartResult {
        start_attempt: while (true) {
            const finished = blk: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return error.OwnerClosed;
                for (self.slots.items, 0..) |slot, index| {
                    if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
                    if (slot.completion == .running) return .already_running;
                    if (slot.waiters != 0) {
                        self.waiters_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
                        continue :start_attempt;
                    }
                    break :blk self.slots.swapRemove(index);
                }
                var feedback_index: usize = 0;
                while (feedback_index < self.feedback.items.len) {
                    const item = self.feedback.items[feedback_index];
                    if (std.mem.eql(u8, item.child_id, child_id) and item.receipt.state.load(.seq_cst) != .queued and item.reported == item.receipt.state.load(.seq_cst)) {
                        _ = self.feedback.swapRemove(feedback_index);
                        item.deinit(self.alloc);
                    } else feedback_index += 1;
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
        self.mutex.lockUncancelable(io_mod.getIo());
        var slot: ?*Slot = null;
        for (self.slots.items) |candidate| {
            if (std.mem.eql(u8, candidate.child_id, child_id)) {
                slot = candidate;
                break;
            }
        }
        const active = slot orelse {
            self.mutex.unlock(io_mod.getIo());
            return self.observe(child_id);
        };
        active.waiters += 1;
        self.mutex.unlock(io_mod.getIo());
        active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
            error.Timeout, error.Canceled => {},
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        // A finished slot's observation must not follow the registry into a new turn.
        const unpublished = active.completion == .unpublished;
        var observation: WaitError!Observation = switch (active.completion) {
            .published => |completed| completed,
            .unpublished => error.StateUnavailable,
            .running => self.observe(child_id),
        };
        if (observation) |*observed| observed.metrics = active.metrics.snapshot() else |_| {}
        active.waiters -= 1;
        self.waiters_changed.broadcast(io_mod.getIo());
        const reaped = !self.closed and self.takeCompletedSlotLocked(active);
        self.mutex.unlock(io_mod.getIo());
        if (reaped) destroySlot(self, active);
        if (unpublished) return error.StateUnavailable;
        return observation;
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

    /// The parent drains tool callers before releasing its borrowed context.
    pub fn cancelAndJoin(self: *Owner, child_id: []const u8) void {
        const slot = blk: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.slots.items) |candidate| {
                if (!std.mem.eql(u8, candidate.child_id, child_id)) continue;
                if (candidate.completion == .running) {
                    candidate.cancel.store(true, .seq_cst);
                    // Stop approval waits without changing explicit cancellation to interruption.
                    if (candidate.worker) |worker| worker.requestShutdown();
                }
                candidate.waiters += 1;
                break :blk candidate;
            }
            return;
        };
        debug_trace.eventf("subagent", "steering_child_join_started", .{}, "child_id={s}", .{child_id});
        if (slot.thread) |thread| {
            thread.join();
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        slot.thread = null;
        slot.waiters -= 1;
        self.waiters_changed.broadcast(io_mod.getIo());
        const unpublished = slot.completion == .unpublished;
        const reaped = self.takeCompletedSlotLocked(slot);
        self.mutex.unlock(io_mod.getIo());
        if (reaped) destroySlot(self, slot);
        if (unpublished) debugFailure(child_id, "cancel_join", error.StateUnavailable);
        debug_trace.eventf("subagent", "steering_child_join_finished", .{}, "child_id={s}", .{child_id});
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
            destroySlot(self, slot);
        }
        self.slots.deinit(self.alloc);
        for (self.feedback.items) |item| item.deinit(self.alloc);
        self.feedback.deinit(self.alloc);
        self.* = undefined;
    }

    fn takeCompletedSlotLocked(self: *Owner, slot: *Slot) bool {
        for (self.slots.items, 0..) |candidate, candidate_index| {
            if (candidate == slot and candidate.completion != .running and candidate.waiters == 0) {
                _ = self.slots.swapRemove(candidate_index);
                return true;
            }
        }
        return false;
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
    ) ?Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch |err| {
            debugFailure(child_id, "state_lock", err);
            return null;
        };
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return null;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome, failure) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return null;
        };
        self.state_store.save(self.alloc, registry) catch |err| {
            debugFailure(child_id, "state_save", err);
            return null;
        };
        const child = registry.findById(child_id) orelse return null;
        return .{ .phase = child.phase, .outcome = child.last_outcome, .failure = child.last_failure };
    }
};

fn destroySlot(owner: *Owner, slot: *Slot) void {
    if (slot.thread) |thread| thread.join();
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (slot.waiters != 0) owner.waiters_changed.waitUncancelable(io_mod.getIo(), &owner.mutex);
    owner.mutex.unlock(io_mod.getIo());
    std.debug.assert(slot.route_refs == 0);
    owner.alloc.free(slot.child_id);
    owner.alloc.destroy(slot);
}

test "child feedback deduplicates operations and bounds queued receipts" {
    const alloc = std.testing.allocator;
    var worker = worker_runtime.WorkerRuntime{};
    var owner = Owner{ .alloc = alloc, .sessions = undefined, .state_store = undefined, .services = undefined, .authority_resolver = undefined, .approvals = undefined };
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child"), .worker = &worker, .work_id = "work" };
    try owner.slots.append(alloc, slot);
    defer {
        slot.worker = null;
        worker.deinit(alloc);
        owner.deinit();
    }
    try std.testing.expect(worker.beginDirectProcessing(7));
    const fingerprint = [_]u8{1} ** 32;
    try std.testing.expect((try owner.steer("child", "previous-work", "first", fingerprint, "same text")) == .waiting);
    try std.testing.expectEqual(@as(usize, 0), worker.queuedPromptCount());
    try std.testing.expect(owner.feedbackReplay("first", fingerprint) == null);
    try std.testing.expectEqual(types.SteeringDelivery.queued, (try owner.steer("child", "work", "first", fingerprint, "same text")).receipt);
    try std.testing.expectEqual(types.SteeringDelivery.queued, (try owner.steer("child", "work", "first", fingerprint, "same text")).receipt);
    try std.testing.expect((try owner.steer("child", "work", "first", [_]u8{2} ** 32, "different")) == .conflict);
    try std.testing.expectEqual(@as(usize, 1), worker.queuedPromptCount());
    for (1..64) |index| {
        const id = try std.fmt.allocPrint(alloc, "feedback-{d}", .{index});
        defer alloc.free(id);
        try std.testing.expectEqual(types.SteeringDelivery.queued, (try owner.steer("child", "work", id, fingerprint, "same text")).receipt);
    }
    try std.testing.expect((try owner.steer("child", "work", "overflow", fingerprint, "same text")) == .capacity);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try worker.takeSteeringBoundaryInto(alloc, arena.allocator(), 7, .model);
    try std.testing.expectEqual(@as(usize, 64), result.continue_turn.len);
    try std.testing.expectEqual(types.SteeringDelivery.applied, owner.feedbackReplay("first", fingerprint).?.receipt);
    try std.testing.expectEqual(@as(usize, 64), (try owner.feedbackUpdates(arena.allocator())).len);
    owner.acknowledgeFeedback("other-child", "first", .applied);
    try std.testing.expectEqual(@as(usize, 64), (try owner.feedbackUpdates(arena.allocator())).len);
    owner.acknowledgeFeedback("child", "first", .applied);
    try std.testing.expectEqual(@as(usize, 63), (try owner.feedbackUpdates(arena.allocator())).len);
}

fn checkFeedbackAllocation(alloc: Allocator) !void {
    var owner = Owner{ .alloc = alloc, .sessions = undefined, .state_store = undefined, .services = undefined, .authority_resolver = undefined, .approvals = undefined };
    defer owner.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer {
        for (owner.slots.items) |slot| slot.worker = null;
        worker.deinit(alloc);
    }
    {
        const slot = try alloc.create(Slot);
        errdefer alloc.destroy(slot);
        slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child"), .worker = &worker, .work_id = "work" };
        errdefer alloc.free(slot.child_id);
        try owner.slots.append(alloc, slot);
    }
    try std.testing.expect(worker.beginDirectProcessing(1));
    const result = try owner.steer("child", "work", "message", [_]u8{1} ** 32, "feedback");
    try std.testing.expectEqual(types.SteeringDelivery.queued, result.receipt);
}

test "child feedback allocation failure preserves ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFeedbackAllocation, .{});
}

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    const outcome = runOne(slot);
    // Startup must not inspect the old slot between saved and in-memory completion.
    // Take owner before registry, matching cancellation and approval lock ordering.
    owner.mutex.lockUncancelable(io_mod.getIo());
    const completed = owner.finish(slot.child_id, outcome.work_id, outcome.outcome, outcome.failure);
    slot.completion = if (completed) |value| .{ .published = value } else .unpublished;
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
    turn.live_metrics = &slot.metrics;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = turn.workerRuntime();
    slot.work_id = turn.active_work_id;
    if (slot.cancel.load(.seq_cst)) slot.worker.?.requestShutdown();
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
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "child turn admitted child_id={s} work_id={s} provider={s} model={s} effort={s}",
        .{
            slot.child_id,
            work_id,
            @tagName(admission.provider),
            admission.model,
            admission.effort.label(),
        },
    );
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
    slot.work_id = null;
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

test "subagent completion takes the owner lock before the registry lock" {
    const alloc = std.testing.allocator;
    const Harness = struct {
        owner: *Owner = undefined,
        outcome: child_state.Outcome,
        fail_save: bool,
        finishing: bool = false,
        checked: bool = false,
        owner_was_unlocked: bool = false,

        fn capture(_: ?*anyopaque, allocator: Allocator, request: execution.CaptureRequest) execution.ServiceError!domain.AdmissionSnapshot {
            return domain.captureAdmission(allocator, .{
                .parent_id = request.parent_id,
                .source_id = request.source_id,
                .model = request.preferences.model,
                .effort = request.preferences.effort,
            }) catch return error.AdmissionFailed;
        }

        fn run(raw: ?*anyopaque, _: *execution.TurnContext, _: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.finishing = true;
            return if (self.outcome == .cancelled) error.Cancelled else .completed;
        }

        fn tryLock(raw: ?*anyopaque, file: std.Io.File) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.finishing) {
                self.checked = true;
                if (self.owner.mutex.tryLock()) {
                    self.owner_was_unlocked = true;
                    self.owner.mutex.unlock(io_mod.getIo());
                }
            }
            return file.tryLock(io_mod.getIo(), .exclusive);
        }

        fn syncFile(raw: ?*anyopaque, file: std.Io.File) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.finishing and self.fail_save) return error.InputOutput;
            try file.sync(io_mod.getIo());
        }
    };
    for ([_]struct { outcome: child_state.Outcome, fail_save: bool }{
        .{ .outcome = .completed, .fail_save = false },
        .{ .outcome = .cancelled, .fail_save = false },
        .{ .outcome = .completed, .fail_save = true },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        var sessions = try session_store.Store.initFromHome(alloc, root, root);
        defer sessions.deinit(alloc);
        for ([_][]const u8{ "completion-parent", "completion-child" }) |id| {
            var writable = try sessions.startWritableSession(alloc, .{
                .id = @constCast(id),
                .origin_workspace_root = @constCast(root),
                .workspace_root = @constCast(root),
                .created_at_ms = 1,
                .updated_at_ms = 1,
                .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
            });
            writable.deinit(alloc);
        }
        var approvals = approval_registry.Registry{ .alloc = alloc };
        defer approvals.deinit();
        var harness = Harness{ .outcome = case.outcome, .fail_save = case.fail_save };
        var owner = Owner{
            .alloc = alloc,
            .sessions = &sessions,
            .state_store = .{ .sessions = &sessions, .parent_id = "completion-parent" },
            .services = .{ .context = &harness, .capture_fn = Harness.capture, .run_fn = Harness.run },
            .authority_resolver = undefined,
            .approvals = &approvals,
        };
        defer owner.deinit();
        harness.owner = &owner;
        {
            var registry = try child_state.Registry.init(alloc, "completion-parent");
            defer registry.deinit(alloc);
            try registry.appendPersistent(alloc, "completion-child", "reviewer", "", .{
                .id = @constCast("completion-work"),
                .message = @constCast("reply"),
                .created_at_ms = 1,
            });
            try owner.state_store.save(alloc, registry);
        }
        owner.state_store.options = .{
            .replace_ops = .{ .ctx = &harness, .sync_file = Harness.syncFile },
            .lock_ops = .{ .ctx = &harness, .try_lock = Harness.tryLock },
        };
        var slot = Slot{ .owner = &owner, .child_id = @constCast("completion-child") };
        slotMain(&slot);
        harness.finishing = false;
        try std.testing.expectEqual(true, harness.checked);
        try std.testing.expectEqual(false, harness.owner_was_unlocked);
        try std.testing.expect(slot.done.isSet());
        try std.testing.expect(slot.worker == null);
        const expected: std.meta.Tag(@TypeOf(slot.completion)) = if (case.fail_save) .unpublished else .published;
        try std.testing.expectEqual(expected, std.meta.activeTag(slot.completion));
        try std.testing.expect(owner.mutex.tryLock());
        owner.mutex.unlock(io_mod.getIo());
        var lock = try owner.state_store.acquireLock(alloc);
        defer lock.release();
        var saved = try owner.state_store.load(alloc);
        defer saved.deinit(alloc);
        try std.testing.expectEqual(if (case.fail_save) child_state.Phase.running else .idle, saved.children[0].phase);
        try std.testing.expectEqual(if (case.fail_save) null else case.outcome, saved.children[0].last_outcome);
    }
}

test "managed owner cancellation join wakes pending permission" {
    try testCancellationJoin(.pending);
}

test "managed owner cancellation join stops late permission registration" {
    try testCancellationJoin(.before_permission);
}

test "managed owner cancellation join reaches worker attached after cancellation" {
    try testCancellationJoin(.before_attachment);
}

const CancellationJoinTest = struct {
    owner: *Owner,
    slot: *Slot,
    start: std.Io.Event = .unset,
    entered: std.Io.Event = .unset,
    permission: std.Io.Event = .unset,
    registered: std.Io.Event = .unset,
    returned: std.Io.Event = .unset,
    finish: std.Io.Event = .unset,
    turn: ?*execution.TurnContext = null,
    request_id: u64 = 0,
    decision: ?types.ToolPermissionDecision = null,
    effects: usize = 0,
    commits: usize = 0,

    fn childMain(self: *@This()) void {
        self.start.waitUncancelable(io_mod.getIo());
        slotMain(self.slot);
    }

    fn joinMain(self: *@This()) void {
        self.owner.cancelAndJoin("child");
    }

    fn capture(_: ?*anyopaque, alloc: Allocator, request: execution.CaptureRequest) execution.ServiceError!domain.AdmissionSnapshot {
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
        }) catch return error.AdmissionFailed;
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, _: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.turn = turn;
        defer {
            self.returned.set(io_mod.getIo());
            self.finish.waitUncancelable(io_mod.getIo());
        }
        const worker = turn.workerRuntime();
        worker.worker_mutex.lockUncancelable(io_mod.getIo());
        worker.worker_processing = true;
        worker.worker_mutex.unlock(io_mod.getIo());
        self.entered.set(io_mod.getIo());
        self.permission.waitUncancelable(io_mod.getIo());
        var response = worker.requestPermissionBlockingObserved(
            turn.alloc,
            .{ .label = "review child action" },
            null,
            .{ .context = self, .observe_fn = observe },
        ) catch return error.ProviderFailed;
        defer response.deinit();
        self.decision = response.decision;
        if (cancel.load(.seq_cst) or worker.isCancelRequested()) return error.Cancelled;
        self.effects += 1;
        return .completed;
    }

    fn observe(raw: *anyopaque, _: *worker_runtime.WorkerRuntime, request: permission_request.PermissionRequest) error{ OutOfMemory, PermissionRegistrationFailed, PermissionCapacityExceeded }!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const turn = self.turn.?;
        Owner.phaseTransition(self.owner, "child", "work", .awaiting_approval) catch
            return error.PermissionRegistrationFailed;
        self.owner.approvals.registerTool("approval", "child", "parent", "work", request, &.{}, turn.approval_worker_route.?, 1) catch
            return error.PermissionRegistrationFailed;
        self.request_id = request.id;
        self.registered.set(io_mod.getIo());
    }

    fn commit(raw: *anyopaque) worker_runtime.WorkerRuntime.PermissionCommitError!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.commits += 1;
    }

    fn rescue(self: *@This()) void {
        self.owner.mutex.lockUncancelable(io_mod.getIo());
        defer self.owner.mutex.unlock(io_mod.getIo());
        self.slot.cancel.store(true, .seq_cst);
        if (self.slot.worker) |worker| worker.requestShutdown();
    }

    fn wait(event: *std.Io.Event) !void {
        try event.waitTimeout(io_mod.getIo(), .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(1000),
        } });
    }
};

fn testCancellationJoin(timing: enum { pending, before_permission, before_attachment }) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var sessions = try session_store.Store.initFromHome(alloc, root, root);
    defer sessions.deinit(alloc);
    for ([_][]const u8{ "parent", "child" }) |id| {
        var writable = try sessions.startWritableSession(alloc, .{
            .id = @constCast(id),
            .origin_workspace_root = @constCast(root),
            .workspace_root = @constCast(root),
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
        });
        writable.deinit(alloc);
    }
    const state_store = child_state.Store{ .sessions = &sessions, .parent_id = "parent" };
    {
        var registry = try child_state.Registry.init(alloc, "parent");
        defer registry.deinit(alloc);
        try registry.appendOneOff(alloc, "child", .{
            .id = @constCast("work"),
            .message = @constCast("child request"),
            .created_at_ms = 1,
        });
        try state_store.save(alloc, registry);
    }
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = state_store,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child") };
    try owner.slots.append(alloc, slot);
    var fixture = CancellationJoinTest{ .owner = &owner, .slot = slot };
    owner.services = .{ .context = &fixture, .capture_fn = CancellationJoinTest.capture, .run_fn = CancellationJoinTest.run };
    slot.thread = try std.Thread.spawn(.{}, CancellationJoinTest.childMain, .{&fixture});
    // Release every gate and stop the real worker even when an assertion fails.
    errdefer {
        fixture.start.set(io_mod.getIo());
        fixture.permission.set(io_mod.getIo());
        fixture.finish.set(io_mod.getIo());
    }
    if (timing != .before_attachment) {
        fixture.start.set(io_mod.getIo());
        try CancellationJoinTest.wait(&fixture.entered);
    }
    if (timing == .pending) {
        fixture.permission.set(io_mod.getIo());
        try CancellationJoinTest.wait(&fixture.registered);
    }
    var rescued = false;
    {
        const joiner = try std.Thread.spawn(.{}, CancellationJoinTest.joinMain, .{&fixture});
        var route_pinned = false;
        const route = workerRoute(slot);
        defer joiner.join();
        defer {
            fixture.rescue();
            fixture.start.set(io_mod.getIo());
            fixture.permission.set(io_mod.getIo());
            fixture.finish.set(io_mod.getIo());
            if (route_pinned) route.release_fn(route.context);
        }
        // The owner lock makes cancellation observation occur after its worker request.
        var cancelled = false;
        for (0..1000) |_| {
            owner.mutex.lockUncancelable(io_mod.getIo());
            cancelled = slot.cancel.load(.seq_cst);
            owner.mutex.unlock(io_mod.getIo());
            if (cancelled) break;
            io_mod.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(cancelled);
        fixture.start.set(io_mod.getIo());
        try CancellationJoinTest.wait(&fixture.entered);
        route_pinned = route.pin_fn(route.context);
        try std.testing.expect(route_pinned);
        fixture.permission.set(io_mod.getIo());
        // Rescue blocked permission waits so regressions fail instead of hanging.
        rescued = if (CancellationJoinTest.wait(&fixture.returned)) |_| false else |_| blk: {
            fixture.rescue();
            try CancellationJoinTest.wait(&fixture.returned);
            break :blk true;
        };
        try std.testing.expectEqual(@as(?types.ToolPermissionDecision, .deny), fixture.decision);
        for ([_]types.ToolPermissionDecision{ .once, .deny }) |decision| {
            try std.testing.expectEqual(worker_runtime.PermissionSubmissionResult.no_pending, try route.submit_fn(
                route.context,
                fixture.request_id,
                permission_request.OwnedPermissionResponse.init(alloc, decision, null),
                .{ .context = &fixture, .commit_fn = CancellationJoinTest.commit },
            ));
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.commits);
        try std.testing.expect(!slot.shutdown.load(.seq_cst));
        fixture.finish.set(io_mod.getIo());
        // Detach invalidates the approval, but cannot release the worker while pinned.
        for (0..1000) |_| {
            if (approvals.pendingRevision() >= 2) break;
            io_mod.sleep(std.time.ns_per_ms);
        }
        try std.testing.expectEqual(@as(u64, 2), approvals.pendingRevision());
        owner.mutex.lockUncancelable(io_mod.getIo());
        const retained = slot.worker != null and slot.route_refs == 1 and slot.completion == .running;
        owner.mutex.unlock(io_mod.getIo());
        try std.testing.expect(retained);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.effects);
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
    const observation = try owner.observe("child");
    try std.testing.expectEqual(child_state.Outcome.cancelled, observation.outcome.?);
    try std.testing.expect(observation.failure == null);
    var pending = try approvals.firstPendingRequest(alloc, "parent");
    defer if (pending) |*request| request.deinit(alloc);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(false, rescued);
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
    const Waiter = struct {
        owner: *Owner,
        result: ?WaitError = null,
        fn run(self: *@This()) void {
            _ = self.owner.wait("child", .{ .clock = .awake, .raw = .fromSeconds(30) }) catch |err| {
                self.result = err;
                return;
            };
        }
    };
    var waiter = Waiter{ .owner = &owner };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    var joined = false;
    defer if (!joined) {
        slot.done.set(io_mod.getIo());
        thread.join();
    };
    var pinned = false;
    for (0..1000) |_| {
        owner.mutex.lockUncancelable(io_mod.getIo());
        pinned = slot.waiters == 1;
        const reaped = if (pinned) owner.takeCompletedSlotLocked(slot) else false;
        owner.mutex.unlock(io_mod.getIo());
        try std.testing.expect(!reaped);
        if (pinned) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(pinned);
    slot.done.set(io_mod.getIo());
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(?WaitError, error.StateUnavailable), waiter.result);
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
}

test "subagent wait returns its completed observation after the registry advances" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var parent = try sessions.startWritableSession(alloc, .{
        .id = @constCast("wait-parent"),
        .origin_workspace_root = @constCast(home),
        .workspace_root = @constCast(home),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    });
    defer parent.deinit(alloc);
    const store = child_state.Store{ .sessions = &sessions, .parent_id = "wait-parent" };
    var registry = try child_state.Registry.init(alloc, "wait-parent");
    defer registry.deinit(alloc);
    try registry.appendPersistent(alloc, "child", "reviewer", "", .{ .id = @constCast("old-work"), .message = @constCast("old task"), .created_at_ms = 1 });
    try registry.finish(alloc, "child", "old-work", .completed, null);
    _ = try registry.startPersistentWork(alloc, "reviewer", null, .{ .id = @constCast("new-work"), .message = @constCast("new task"), .created_at_ms = 2 });
    try store.save(alloc, registry);
    var owner = Owner{ .alloc = alloc, .sessions = &sessions, .state_store = store, .services = undefined, .authority_resolver = undefined, .approvals = undefined };
    defer owner.deinit();
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child"), .completion = .{ .published = .{ .phase = .idle, .outcome = .completed } } };
    try owner.slots.append(alloc, slot);
    slot.done.set(io_mod.getIo());
    const observed = try owner.wait("child", .{ .clock = .awake, .raw = .fromMilliseconds(1) });
    try std.testing.expectEqual(child_state.Phase.idle, observed.phase);
    try std.testing.expectEqual(@as(?child_state.Outcome, .completed), observed.outcome);
    const current = try owner.observe("child");
    try std.testing.expectEqual(child_state.Phase.running, current.phase);
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
