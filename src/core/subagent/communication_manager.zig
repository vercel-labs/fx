const std = @import("std");
const session_child_store = @import("../session/session_child_store.zig");
const session_store = @import("../session/session_store.zig");
const communication = @import("communication.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const max_ancestry_depth: usize = 1024;

pub const Error = error{
    OutOfMemory,
    SessionNotFound,
    InvalidRequest,
    LockBusy,
    LockUnsupported,
    StoreUnavailable,
    InvalidRecord,
    CommitIndeterminate,
    CapacityExceeded,
    StaleCursor,
    ContextTooLarge,
    OperationReplayExpired,
};

pub const BoundaryProjection = union(enum) {
    wait,
    inject: struct {
        context: []u8,
        delivery_id: []u8,
        generation: u64,
        through_sequence: u64,
        start_offset: u64,
        end_offset: u64,
        total_bytes: u64,
    },

    /// Releases the owned trusted-context projection, if present.
    pub fn deinit(self: *BoundaryProjection, alloc: Allocator) void {
        switch (self.*) {
            .wait => {},
            .inject => |value| {
                alloc.free(value.context);
                alloc.free(value.delivery_id);
            },
        }
        self.* = undefined;
    }
};

pub const PollOutcome = union(enum) {
    inactive,
    pending: i64,
    emitted: struct {
        coalesced_ticks: u32,
        next_check_ms: ?i64,
    },
    stopped,
};

/// Thin effectful shell over the pure communication ledger. It never opens a
/// transcript writer and every mutation uses `subagent-control.lock`.
pub const Manager = struct {
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options = .{},

    pub fn publish(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        input: communication.DeliveryInput,
    ) Error!communication.AppendResult {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            owner_session_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = owner_session_id,
        };
        var lock = store.acquireLock() catch |err| return mapLock(err);
        defer lock.release();
        var ledger = try loadOrInit(alloc, store, owner_session_id);
        defer ledger.deinit(alloc);
        const result = communication.appendDelivery(alloc, &ledger, input) catch |err|
            return mapMutation(err);
        if (result == .duplicate) return result;
        try save(store, alloc, ledger);
        return result;
    }

    /// Returns an owned page from read-only control authority. The cursor is not
    /// advanced until the caller confirms successful turn-boundary injection.
    pub fn page(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        expected_generation: ?u64,
        limit: usize,
    ) Error!communication.Page {
        return self.pageProjection(
            alloc,
            owner_session_id,
            consumer_id,
            target_session_id,
            expected_generation,
            limit,
        );
    }

    fn pageProjection(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        expected_generation: ?u64,
        limit: usize,
    ) Error!communication.Page {
        var locked = try AuthorizedLocks.acquire(
            alloc,
            self.sessions,
            owner_session_id,
            target_session_id,
            self.child_store_options,
        );
        defer locked.deinit(alloc);
        return self.pageProjectionLocked(
            alloc,
            &locked,
            owner_session_id,
            consumer_id,
            target_session_id,
            expected_generation,
            limit,
        );
    }

    fn pageProjectionLocked(
        self: *Manager,
        alloc: Allocator,
        locked: *AuthorizedLocks,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        expected_generation: ?u64,
        limit: usize,
    ) Error!communication.Page {
        _ = self;
        const owner = locked.find(owner_session_id) orelse return error.InvalidRequest;
        const store = communication_store.Store{
            .capability = &owner.capability,
            .expected_session_id = owner_session_id,
        };
        const maybe_ledger = store.loadOptional(alloc) catch |err| return mapLoad(err);
        if (maybe_ledger == null) {
            return .{
                .generation = 0,
                .deliveries = try alloc.alloc(communication.Delivery, 0),
                .through_sequence = 0,
                .has_more = false,
            };
        }
        var ledger = maybe_ledger.?;
        defer ledger.deinit(alloc);
        return communication.pageForTarget(
            alloc,
            ledger,
            consumer_id,
            target_session_id,
            expected_generation,
            limit,
        ) catch |err| return mapMutation(err);
    }

    /// Reads and renders parent delivery only while constructing a new turn.
    /// The caller acknowledges `through_sequence` after successful injection;
    /// running and idle parents are never steered or acknowledged here.
    pub fn prepareParentBoundaryPage(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        state: communication.ParentDeliveryState,
        expected_generation: ?u64,
        limit: usize,
    ) Error!communication.ParentPage {
        if (communication.decideParentBoundary(state) == .wait) {
            return .{
                .generation = expected_generation orelse 0,
                .deliveries = try alloc.alloc(communication.ParentDeliveryPart, 0),
                .through_sequence = 0,
                .has_more = false,
            };
        }
        var locked = try AuthorizedLocks.acquire(
            alloc,
            self.sessions,
            owner_session_id,
            target_session_id,
            self.child_store_options,
        );
        defer locked.deinit(alloc);
        const owner = locked.find(owner_session_id) orelse return error.InvalidRequest;
        const store = communication_store.Store{
            .capability = &owner.capability,
            .expected_session_id = owner_session_id,
        };
        const maybe_ledger = store.loadOptional(alloc) catch |err| return mapLoad(err);
        if (maybe_ledger == null) {
            return .{
                .generation = 0,
                .deliveries = try alloc.alloc(communication.ParentDeliveryPart, 0),
                .through_sequence = 0,
                .has_more = false,
            };
        }
        var ledger = maybe_ledger.?;
        defer ledger.deinit(alloc);
        return communication.pageForParentTurn(
            alloc,
            ledger,
            consumer_id,
            target_session_id,
            expected_generation,
            limit,
        ) catch |err| return mapMutation(err);
    }

    /// Reads and renders one parent delivery only while constructing a new
    /// turn. The caller acknowledges the returned part after successful
    /// injection; running and idle parents are never steered or acknowledged.
    pub fn prepareParentBoundary(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        state: communication.ParentDeliveryState,
        expected_generation: ?u64,
    ) Error!BoundaryProjection {
        var pending = try self.prepareParentBoundaryPage(
            alloc,
            owner_session_id,
            consumer_id,
            target_session_id,
            state,
            expected_generation,
            1,
        );
        defer pending.deinit(alloc);
        if (pending.deliveries.len == 0) return .wait;
        const context = communication.renderTrustedContext(
            alloc,
            pending.deliveries,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TrustedContextTooLarge => error.ContextTooLarge,
        };
        errdefer alloc.free(context);
        const selected = pending.deliveries[0];
        const delivery_id = try alloc.dupe(u8, selected.id);
        return .{ .inject = .{
            .context = context,
            .delivery_id = delivery_id,
            .generation = pending.generation,
            .through_sequence = selected.sequence,
            .start_offset = switch (selected.payload) {
                .message => |message| message.offset,
                else => 0,
            },
            .end_offset = switch (selected.payload) {
                .message => |message| message.end_offset,
                else => 0,
            },
            .total_bytes = switch (selected.payload) {
                .message => |message| message.total_bytes,
                else => 0,
            },
        } };
    }

    pub fn acknowledge(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        sequence: u64,
    ) Error!void {
        return self.acknowledgeProjection(
            alloc,
            owner_session_id,
            consumer_id,
            target_session_id,
            sequence,
        );
    }

    pub fn acknowledgeParentBoundary(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        acknowledgement: communication.ParentAcknowledgement,
    ) Error!void {
        _ = try self.acknowledgeParentBoundaryWithFinalResultSignal(
            alloc,
            owner_session_id,
            consumer_id,
            target_session_id,
            acknowledgement,
        );
    }

    pub fn acknowledgeParentBoundaryWithFinalResultSignal(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        acknowledgement: communication.ParentAcknowledgement,
    ) Error!bool {
        var locked = try AuthorizedLocks.acquire(
            alloc,
            self.sessions,
            owner_session_id,
            target_session_id,
            self.child_store_options,
        );
        defer locked.deinit(alloc);
        const owner = locked.find(owner_session_id) orelse return error.InvalidRequest;
        const store = communication_store.Store{
            .capability = &owner.capability,
            .expected_session_id = owner_session_id,
        };
        var ledger = try loadOrInit(alloc, store, owner_session_id);
        defer ledger.deinit(alloc);
        const prior_generation = ledger.generation;
        communication.acknowledgeParentTurn(
            alloc,
            &ledger,
            consumer_id,
            target_session_id,
            acknowledgement,
        ) catch |err| return mapMutation(err);
        if (ledger.generation != prior_generation) try save(store, alloc, ledger);
        return communication.stableFinalResultFullyAcknowledged(
            ledger,
            consumer_id,
            target_session_id,
            acknowledgement.delivery_id,
        );
    }

    fn acknowledgeProjection(
        self: *Manager,
        alloc: Allocator,
        owner_session_id: []const u8,
        consumer_id: []const u8,
        target_session_id: []const u8,
        sequence: u64,
    ) Error!void {
        var locked = try AuthorizedLocks.acquire(
            alloc,
            self.sessions,
            owner_session_id,
            target_session_id,
            self.child_store_options,
        );
        defer locked.deinit(alloc);
        const owner = locked.find(owner_session_id) orelse return error.InvalidRequest;
        const store = communication_store.Store{
            .capability = &owner.capability,
            .expected_session_id = owner_session_id,
        };
        var ledger = try loadOrInit(alloc, store, owner_session_id);
        defer ledger.deinit(alloc);
        const prior_generation = ledger.generation;
        communication.acknowledgeTarget(
            alloc,
            &ledger,
            consumer_id,
            target_session_id,
            sequence,
        ) catch |err| return mapMutation(err);
        if (ledger.generation != prior_generation) try save(store, alloc, ledger);
    }

    pub fn captureWorkPolicy(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        policy: domain.NotificationPolicy,
        started_at_ms: i64,
    ) Error!?i64 {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        var store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = store.acquireLock() catch |err| return mapLock(err);
        defer lock.release();
        return captureWorkPolicyLocked(
            alloc,
            store,
            child_id,
            work_id,
            policy,
            started_at_ms,
        );
    }

    /// Polls only the durable control and communication snapshots. Delivery
    /// identity is derived from the stored due time; no model or worker is
    /// touched.
    pub fn poll(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) Error!PollOutcome {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        var communication_state = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = communication_state.acquireLock() catch |err| return mapLock(err);
        defer lock.release();
        const control = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = control.load(alloc) catch return error.InvalidRecord;
        defer record.deinit(alloc);
        const policy_existed = blk: {
            var before_reconciliation = try loadOrInit(
                alloc,
                communication_state,
                child_id,
            );
            defer before_reconciliation.deinit(alloc);
            if (record.state == .archived or record.parent_id == null) {
                const captured = before_reconciliation.work_notifications.len;
                _ = communication.stopAllWorkNotifications(&before_reconciliation);
                communication.compactStoppedWorkNotifications(
                    alloc,
                    &before_reconciliation,
                ) catch return error.OutOfMemory;
                if (captured != before_reconciliation.work_notifications.len) {
                    try save(communication_state, alloc, before_reconciliation);
                }
                return .stopped;
            }
            break :blk communication.findWorkNotification(
                before_reconciliation.work_notifications,
                work_id,
            ) != null;
        };
        _ = try reconcileTerminalsLocked(
            alloc,
            communication_state,
            record,
        );
        var ledger = try loadOrInit(alloc, communication_state, child_id);
        defer ledger.deinit(alloc);
        const queued = findQueuedWork(record.queue, work_id) orelse {
            const orphaned = communication.findWorkNotification(
                ledger.work_notifications,
                work_id,
            ) orelse return .inactive;
            _ = communication.stopWorkNotification(orphaned);
            communication.compactStoppedWorkNotifications(alloc, &ledger) catch
                return error.OutOfMemory;
            try save(communication_state, alloc, ledger);
            return .stopped;
        };
        const state = notificationState(queued.status) orelse return .inactive;
        const work = communication.findWorkNotification(
            ledger.work_notifications,
            queued.id,
        ) orelse return if (policy_existed) .stopped else .inactive;
        if (work.stopped) {
            communication.compactStoppedWorkNotifications(alloc, &ledger) catch
                return error.OutOfMemory;
            try save(communication_state, alloc, ledger);
            return .stopped;
        }
        if (work.policy.report_interval_ms == null) return .inactive;
        const scheduled_due_ms = work.next_due_ms orelse return .inactive;
        const decision = communication.pollNotification(work, state, now_ms) catch |err|
            return mapMutation(err);
        switch (decision) {
            .none => {
                const next_check_ms = communication.nextNotificationCheck(work.*) catch |err|
                    return mapMutation(err);
                return if (next_check_ms) |value| .{ .pending = value } else .inactive;
            },
            .stop => {
                communication.compactStoppedWorkNotifications(alloc, &ledger) catch
                    return error.OutOfMemory;
                try save(communication_state, alloc, ledger);
                return .stopped;
            },
            .emit => |ticks| {
                const parent_id = record.parent_id orelse return .inactive;
                const tick_id = communication.stableIntervalDeliveryId(
                    child_id,
                    queued.id,
                    scheduled_due_ms,
                );
                _ = communication.appendDelivery(alloc, &ledger, .{
                    .id = &tick_id,
                    .source_id = child_id,
                    .target_id = parent_id,
                    .work_id = queued.id,
                    .timestamp_ms = now_ms,
                    .payload = .{ .interval = .{
                        .state = state,
                        .coalesced_ticks = ticks,
                    } },
                }) catch |err| return mapMutation(err);
                const next_check_ms = communication.nextNotificationCheck(work.*) catch |err|
                    return mapMutation(err);
                if (next_check_ms == null) {
                    communication.compactStoppedWorkNotifications(alloc, &ledger) catch
                        return error.OutOfMemory;
                }
                try save(communication_state, alloc, ledger);
                return .{ .emitted = .{
                    .coalesced_ticks = ticks,
                    .next_check_ms = next_check_ms,
                } };
            },
        }
    }

    /// Stops and compacts every work notification policy under the same
    /// durable lock used by polling.
    pub fn stopAndCompactNotifications(
        self: *Manager,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!void {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = store.acquireLock() catch |err| return mapLock(err);
        defer lock.release();
        const existing = store.loadOptional(alloc) catch |err| return mapLoad(err);
        var ledger = existing orelse return;
        defer ledger.deinit(alloc);
        const captured = ledger.work_notifications.len;
        _ = communication.stopAllWorkNotifications(&ledger);
        communication.compactStoppedWorkNotifications(alloc, &ledger) catch
            return error.OutOfMemory;
        const removed = captured - ledger.work_notifications.len;
        if (removed != 0) try save(store, alloc, ledger);
    }
};

const LockedControl = struct {
    id: []u8,
    capability: session_child_store.SessionChildCapability,
    lock: io_mod.TimedAdvisoryLock,

    fn deinit(self: *LockedControl, alloc: Allocator) void {
        self.lock.release();
        self.capability.deinit();
        alloc.free(self.id);
        self.* = undefined;
    }
};

/// Ordered relationship read set. Every page and acknowledgement is decided
/// while the same locks used by relationship mutations remain held.
const AuthorizedLocks = struct {
    items: std.ArrayList(LockedControl) = .empty,

    fn acquire(
        alloc: Allocator,
        sessions: *session_store.Store,
        owner_id: []const u8,
        target_id: []const u8,
        options: session_child_store.Options,
    ) Error!AuthorizedLocks {
        var ids = try discoverAuthorizedIds(
            alloc,
            sessions,
            owner_id,
            target_id,
            options,
        );
        defer freeIds(alloc, &ids);
        sortIds(ids.items);

        var result = AuthorizedLocks{};
        errdefer result.deinit(alloc);
        for (ids.items) |id| {
            var capability = sessions.openSubagentControlCapabilityWritable(
                alloc,
                id,
                options,
            ) catch |err| return mapOpen(err);
            errdefer capability.deinit();
            const control = control_store.Store{
                .capability = &capability,
                .expected_child_id = id,
            };
            var lock = control.acquireLock() catch |err| return mapControlLock(err);
            errdefer lock.release();
            const owned_id = try alloc.dupe(u8, id);
            errdefer alloc.free(owned_id);
            try result.items.append(alloc, .{
                .id = owned_id,
                .capability = capability,
                .lock = lock,
            });
            capability = undefined;
            lock = undefined;
        }
        if (!try result.authorizes(alloc, owner_id, target_id)) {
            return error.InvalidRequest;
        }
        return result;
    }

    fn authorizes(
        self: *AuthorizedLocks,
        alloc: Allocator,
        owner_id: []const u8,
        target_id: []const u8,
    ) Error!bool {
        var visited: std.ArrayList([]const u8) = .empty;
        defer visited.deinit(alloc);
        var current = owner_id;
        for (0..max_ancestry_depth) |_| {
            if (std.mem.eql(u8, current, target_id)) return true;
            for (visited.items) |id| {
                if (std.mem.eql(u8, id, current)) return error.InvalidRecord;
            }
            try visited.append(alloc, current);
            const item = self.find(current) orelse return false;
            const control = control_store.Store{
                .capability = &item.capability,
                .expected_child_id = current,
            };
            var record = control.loadOptional(alloc) catch |err| return mapLoadControl(err);
            defer if (record) |*value| value.deinit(alloc);
            const parent_id = if (record) |value| value.parent_id orelse return false else return false;
            const parent = self.find(parent_id) orelse return false;
            current = parent.id;
        }
        return error.InvalidRecord;
    }

    fn find(self: *AuthorizedLocks, id: []const u8) ?*LockedControl {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    fn deinit(self: *AuthorizedLocks, alloc: Allocator) void {
        var index = self.items.items.len;
        while (index > 0) {
            index -= 1;
            self.items.items[index].deinit(alloc);
        }
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

fn discoverAuthorizedIds(
    alloc: Allocator,
    sessions: *session_store.Store,
    owner_id: []const u8,
    target_id: []const u8,
    options: session_child_store.Options,
) Error!std.ArrayList([]u8) {
    domain.validateId(owner_id) catch return error.InvalidRequest;
    domain.validateId(target_id) catch return error.InvalidRequest;
    var ids: std.ArrayList([]u8) = .empty;
    errdefer freeIds(alloc, &ids);
    var current = try alloc.dupe(u8, owner_id);
    defer alloc.free(current);
    for (0..max_ancestry_depth) |_| {
        for (ids.items) |id| {
            if (std.mem.eql(u8, id, current)) return error.InvalidRecord;
        }
        const owned_current = try alloc.dupe(u8, current);
        ids.append(alloc, owned_current) catch |err| {
            alloc.free(owned_current);
            return err;
        };
        if (std.mem.eql(u8, current, target_id)) return ids;
        var capability = sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            current,
            options,
        ) catch |err| return mapOpen(err);
        defer capability.deinit();
        const control = control_store.Store{
            .capability = &capability,
            .expected_child_id = current,
        };
        var record = control.loadOptional(alloc) catch |err| return mapLoadControl(err);
        defer if (record) |*value| value.deinit(alloc);
        const parent_id = if (record) |value| value.parent_id orelse return error.InvalidRequest else return error.InvalidRequest;
        const next = try alloc.dupe(u8, parent_id);
        alloc.free(current);
        current = next;
    }
    return error.InvalidRecord;
}

fn sortIds(ids: [][]u8) void {
    var index: usize = 1;
    while (index < ids.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, ids[cursor - 1], ids[cursor]) == .gt) : (cursor -= 1) {
            std.mem.swap([]u8, &ids[cursor - 1], &ids[cursor]);
        }
    }
}

fn freeIds(alloc: Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| alloc.free(id);
    ids.deinit(alloc);
}

/// Used when the caller already holds this session's control lock. Saving the
/// immutable work contract before the control admission makes a failed control
/// commit harmless: an explicit retry replaces the stale capture by work ID.
pub fn captureWorkPolicyLocked(
    alloc: Allocator,
    store: communication_store.Store,
    child_id: []const u8,
    work_id: []const u8,
    policy: domain.NotificationPolicy,
    started_at_ms: i64,
) Error!?i64 {
    var ledger = try loadOrInit(alloc, store, child_id);
    defer ledger.deinit(alloc);
    communication.upsertWorkNotification(
        alloc,
        &ledger,
        work_id,
        policy,
        started_at_ms,
    ) catch |err| return mapMutation(err);
    const work = communication.findWorkNotification(
        ledger.work_notifications,
        work_id,
    ) orelse return error.InvalidRecord;
    const next_check_ms = communication.nextNotificationCheck(work.*) catch |err|
        return mapMutation(err);
    try save(store, alloc, ledger);
    return next_check_ms;
}

/// Rebuilds terminal projections from committed control transitions. Stable
/// delivery IDs and event timestamps make retries/restarts exact-once.
pub fn reconcileTerminalsLocked(
    alloc: Allocator,
    store: communication_store.Store,
    record: control_store.Record,
) Error!usize {
    var ledger = try loadOrInit(alloc, store, record.child_id);
    defer ledger.deinit(alloc);
    var repaired: usize = 0;
    var changed = false;
    for (record.queue) |work_item| {
        const terminal_state: domain.State = switch (work_item.status) {
            .completed => .completed,
            .failed => .failed,
            .cancelled => .cancelled,
            else => continue,
        };
        const notification = communication.findWorkNotification(
            ledger.work_notifications,
            work_item.id,
        ) orelse continue;
        changed = communication.applyTerminalStop(notification, terminal_state) or changed;
        if (!communication.terminalEnabled(notification.policy, terminal_state)) continue;
        const timestamp_ms = terminalTransitionTimestamp(
            record.events,
            work_item.id,
            work_item.status,
        ) orelse return error.InvalidRecord;
        const id = communication.stableDeliveryId(
            record.child_id,
            work_item.id,
            @tagName(terminal_state),
        );
        const appended = communication.appendDelivery(alloc, &ledger, .{
            .id = &id,
            .source_id = record.child_id,
            .target_id = work_item.source_id,
            .work_id = work_item.id,
            .timestamp_ms = timestamp_ms,
            .payload = .{ .terminal = terminal_state },
        }) catch |err| return mapMutation(err);
        if (appended == .appended) {
            changed = true;
            repaired += 1;
        }
    }
    if (changed) save(store, alloc, ledger) catch |err| {
        debug_trace.logf(
            "subagent",
            "terminal reconciliation failed child_id={s} repaired={d} outcome={s}",
            .{ record.child_id, repaired, @errorName(err) },
        );
        return err;
    };
    if (repaired != 0) {
        debug_trace.logf(
            "subagent",
            "terminal reconciliation committed child_id={s} repaired={d} outcome=ok",
            .{ record.child_id, repaired },
        );
    }
    return repaired;
}

pub const FinalResultInput = struct {
    child_id: []const u8,
    parent_id: []const u8,
    work_id: []const u8,
    timestamp_ms: i64,
    content: []const u8,
};

/// Appends the mandatory one-off result through the existing message ledger.
/// The stable ID makes normal completion, restart recovery, and retries
/// idempotent. The caller retains ownership of every input slice.
pub fn reconcileFinalResultLocked(
    alloc: Allocator,
    store: communication_store.Store,
    input: FinalResultInput,
) Error!bool {
    var ledger = try loadOrInit(alloc, store, input.child_id);
    defer ledger.deinit(alloc);
    const id = communication.stableDeliveryId(
        input.child_id,
        input.work_id,
        "final-result",
    );
    const appended = communication.appendDelivery(alloc, &ledger, .{
        .id = &id,
        .source_id = input.child_id,
        .target_id = input.parent_id,
        .work_id = input.work_id,
        .timestamp_ms = input.timestamp_ms,
        .payload = .{ .message = @constCast(input.content) },
    }) catch |err| return mapMutation(err);
    if (appended == .duplicate) return false;
    try save(store, alloc, ledger);
    debug_trace.logf(
        "subagent",
        "final result reconciliation committed child_id={s} work_id={s} outcome=ok",
        .{ input.child_id, input.work_id },
    );
    return true;
}

/// Reconciles unresolved tool approvals from canonical work state. This is
/// safe to repeat after an interrupted or indeterminate prior cleanup.
pub fn reconcileApprovalsLocked(
    alloc: Allocator,
    store: communication_store.Store,
    record: control_store.Record,
    timestamp_ms: i64,
) Error!usize {
    const existing = store.loadOptional(alloc) catch |err| return mapLoad(err);
    var ledger = existing orelse return 0;
    defer ledger.deinit(alloc);
    const changed = communication.reconcilePendingWorkApprovals(
        &ledger,
        record.child_id,
        record.queue,
        timestamp_ms,
    ) catch |err| return mapMutation(err);
    if (changed != 0) try save(store, alloc, ledger);
    return changed;
}

fn terminalTransitionTimestamp(
    events: []const domain.Event,
    work_id: []const u8,
    status: domain.QueueStatus,
) ?i64 {
    var index = events.len;
    while (index > 0) {
        index -= 1;
        switch (events[index].kind) {
            .work_transition => |transition| {
                if (transition.current == status and
                    std.mem.eql(u8, transition.work_item_id, work_id))
                {
                    return events[index].timestamp_ms;
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn invalidateApprovalsLocked(
    alloc: Allocator,
    store: communication_store.Store,
    child_id: []const u8,
    status: communication.ApprovalStatus,
    timestamp_ms: i64,
) Error!usize {
    const existing = store.loadOptional(alloc) catch |err| return mapLoad(err);
    var ledger = existing orelse return 0;
    defer ledger.deinit(alloc);
    const changed = communication.invalidatePendingApprovals(
        &ledger,
        child_id,
        status,
        timestamp_ms,
    ) catch |err| return mapMutation(err);
    if (changed != 0) try save(store, alloc, ledger);
    return changed;
}

fn findQueuedWork(
    queue: []const domain.QueuedMessage,
    work_id: []const u8,
) ?domain.QueuedMessage {
    for (queue) |message| {
        if (std.mem.eql(u8, message.id, work_id)) return message;
    }
    return null;
}

fn notificationState(status: domain.QueueStatus) ?domain.State {
    return switch (status) {
        .pending => null,
        .running => .running,
        .awaiting_approval => .awaiting_approval,
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
    };
}

fn loadOrInit(
    alloc: Allocator,
    store: communication_store.Store,
    session_id: []const u8,
) Error!communication.Ledger {
    const existing = store.loadOptional(alloc) catch |err| return mapLoad(err);
    if (existing) |ledger| return ledger;
    return communication.Ledger.init(alloc, session_id) catch
        return error.OutOfMemory;
}

fn save(
    store: communication_store.Store,
    alloc: Allocator,
    ledger: communication.Ledger,
) Error!void {
    store.save(alloc, ledger) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationCommitIndeterminate => error.CommitIndeterminate,
        error.CommunicationCapacityExceeded => error.CapacityExceeded,
        error.InvalidCommunicationRecord,
        error.CommunicationIdentityMismatch,
        => error.InvalidRecord,
        error.CommunicationRecordTooLarge,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapOpen(err: session_store.OpenSubagentControlError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionNotFound => error.SessionNotFound,
        error.InvalidSessionId => error.InvalidRequest,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.SessionChildStoreFailed,
        error.SessionStoreUnavailable,
        => error.StoreUnavailable,
    };
}

fn mapLock(err: communication_store.LockError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationLockBusy => error.LockBusy,
        error.CommunicationLockUnsupported => error.LockUnsupported,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapControlLock(err: control_store.LockError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlLockBusy => error.LockBusy,
        error.ControlLockUnsupported => error.LockUnsupported,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapLoadControl(err: control_store.LoadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlNotFound => error.InvalidRequest,
        error.InvalidControlRecord,
        error.UnsupportedControlSchema,
        error.ControlRecordTooLarge,
        => error.InvalidRecord,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapLoad(err: communication_store.LoadError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommunicationNotFound => error.StoreUnavailable,
        error.InvalidCommunicationRecord,
        error.UnsupportedCommunicationSchema,
        => error.InvalidRecord,
        error.CommunicationRecordTooLarge,
        error.CommunicationPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapMutation(err: communication.MutationError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StaleCursor => error.StaleCursor,
        error.ReplayExpired => error.OperationReplayExpired,
        error.InvalidDelivery,
        error.GenerationExhausted,
        error.SequenceExhausted,
        error.TooManyConsumers,
        error.TooManyRetentionTargets,
        error.InvalidCursor,
        error.InvalidNotification,
        error.UndeclaredMilestone,
        error.DuplicateMilestone,
        error.InvalidApproval,
        error.ApprovalConflict,
        error.AuthorityExhausted,
        => error.InvalidRequest,
        error.CapacityExceeded => error.CapacityExceeded,
    };
}
