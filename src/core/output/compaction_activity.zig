const std = @import("std");

/// Process-local identity, distinct from a turn: one turn can compact repeatedly.
pub const OperationId = enum(u64) { _ };
pub const Origin = enum { manual, automatic, provider_overflow };
pub const Stage = enum { preparation, summary, publication };
pub const Publication = enum { not_published, committed, uncertain };
pub const Outcome = enum { succeeded, no_op, busy, cancelled, failed };

pub const Feedback = struct {
    outcome: Outcome,
    stage: Stage = .preparation,
    publication: Publication = .not_published,
    /// Deliberately retains the original erased host/provider error, not text.
    err: ?anyerror = null,
};

pub fn failure(err: anyerror, stage: Stage, cancelled: bool) Feedback {
    return .{
        .outcome = if (err == error.Cancelled or (cancelled and err == error.Aborted)) .cancelled else .failed,
        .stage = stage,
        .publication = if (err == error.SessionPersistenceUncertain) .uncertain else .not_published,
        .err = err,
    };
}

/// Carried only along the error return that actually escaped compaction.
/// It is not inferred from a previous failed operation or from error text.
pub const ErrorProvenance = struct {
    operation_id: OperationId,
    turn_id: ?u64,
    err: anyerror,
};

pub const Phase = union(enum) {
    preparing,
    running: Stage,
    stopping: Stage,
    terminal: Feedback,
};

pub const Operation = struct {
    id: OperationId,
    turn_id: ?u64,
    origin: Origin,
    phase: Phase = .preparing,
    /// Manual admission resets this when queued; automatic consumers use the turn clock.
    started_at_ms: i64,
    expires_at_ms: ?i64 = null,
    dismissed: bool = false,

    pub fn visible(self: Operation, now_ms: i64) bool {
        if (self.dismissed) return false;
        if (self.expires_at_ms) |expiry| if (now_ms >= expiry) return false;
        return switch (self.phase) {
            .terminal => |feedback| feedback.outcome != .succeeded,
            .preparing, .running, .stopping => true,
        };
    }

    pub fn active(self: Operation) bool {
        return self.phase != .terminal;
    }

    pub fn stage(self: Operation) Stage {
        return switch (self.phase) {
            .preparing => .preparation,
            .running, .stopping => |value| value,
            .terminal => |feedback| feedback.stage,
        };
    }
};

/// Fixed-size, allocation-free copy. No borrowed mutable storage or permission snapshot.
pub const Snapshot = struct {
    revision: u64 = 0,
    operation: ?Operation = null,
};

/// Owned exclusively by WorkerRuntime under worker_mutex. Clock inputs are explicit.
pub const State = struct {
    snapshot: Snapshot = .{},
    next_id: u64 = 1,

    pub fn begin(self: *State, origin: Origin, turn_id: ?u64, now_ms: i64) OperationId {
        const id: OperationId = @fromBackingInt(@intCast(self.next_id));
        // Neither counter is reused within a worker lifetime.
        self.next_id += 1;
        self.snapshot.operation = .{ .id = id, .turn_id = turn_id, .origin = origin, .started_at_ms = now_ms };
        self.snapshot.revision += 1;
        return id;
    }

    pub fn queued(self: *State, id: OperationId, turn_id: u64, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        op.turn_id = turn_id;
        op.started_at_ms = now_ms;
        self.snapshot.revision += 1;
    }

    pub fn running(self: *State, id: OperationId, stage: Stage) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        const next: Phase = if (op.phase == .stopping) .{ .stopping = stage } else .{ .running = stage };
        if (std.meta.eql(op.phase, next)) return;
        op.phase = next;
        self.snapshot.revision += 1;
    }

    pub fn stopping(self: *State, id: OperationId) void {
        const op = self.match(id) orelse return;
        if (!op.active() or op.phase == .stopping) return;
        op.phase = .{ .stopping = op.stage() };
        self.snapshot.revision += 1;
    }

    pub fn settle(self: *State, id: OperationId, feedback: Feedback, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        op.phase = .{ .terminal = feedback };
        op.expires_at_ms = switch (feedback.outcome) {
            .no_op, .busy => now_ms +| 1500,
            .succeeded, .cancelled, .failed => null,
        };
        self.snapshot.revision += 1;
    }

    /// Dismisses only the terminal feedback observed by the caller, never newer work.
    pub fn dismiss(self: *State, id: OperationId, revision: u64) bool {
        if (revision != self.snapshot.revision) return false;
        const op = self.match(id) orelse return false;
        if (op.active() or op.dismissed) return false;
        op.dismissed = true;
        self.snapshot.revision += 1;
        return true;
    }

    pub fn expire(self: *State, id: OperationId, revision: u64, now_ms: i64) bool {
        const op = self.match(id) orelse return false;
        const expiry = op.expires_at_ms orelse return false;
        if (now_ms < expiry) return false;
        return self.dismiss(id, revision);
    }

    fn match(self: *State, id: OperationId) ?*Operation {
        const op = if (self.snapshot.operation) |*value| value else return null;
        return if (op.id == id) op else null;
    }
};

test "compaction activity is bounded and rejects stale updates and dismissals" {
    try std.testing.expect(@sizeOf(State) <= 128);
    var state: State = .{};
    const manual = state.begin(.manual, null, 10);
    state.queued(manual, 7, 20);
    state.running(manual, .summary);
    state.settle(manual, .{ .outcome = .succeeded, .publication = .committed }, 30);
    const settled = state.snapshot;
    state.settle(manual, failure(error.Cancelled, .summary, true), 40);
    try std.testing.expectEqualDeep(settled, state.snapshot);
    const auto = state.begin(.automatic, 7, 50);
    const overflow = state.begin(.provider_overflow, 7, 60);
    try std.testing.expect(manual != auto and auto != overflow);
    try std.testing.expect(state.snapshot.revision > settled.revision);
    state.settle(auto, failure(error.ConnectionTimedOut, .summary, false), 70);
    try std.testing.expect(!state.dismiss(manual, settled.revision));
    try std.testing.expectEqual(overflow, state.snapshot.operation.?.id);
    state.stopping(overflow);
    state.running(overflow, .publication);
    try std.testing.expect(state.snapshot.operation.?.phase == .stopping);
    state.settle(overflow, .{ .outcome = .succeeded, .publication = .committed }, 80);
    try std.testing.expect(!state.snapshot.operation.?.visible(80));
}

test "compaction activity transient expiry and persistent feedback are identity scoped" {
    var state: State = .{};
    for ([_]Outcome{ .no_op, .busy }) |outcome| {
        const id = state.begin(.manual, null, 0);
        state.settle(id, .{ .outcome = outcome }, 100);
        const revision = state.snapshot.revision;
        try std.testing.expect(state.snapshot.operation.?.visible(1599));
        try std.testing.expect(!state.expire(id, revision, 1599));
        try std.testing.expect(state.expire(id, revision, 1600));
        try std.testing.expect(!state.snapshot.operation.?.visible(1600));
    }
    for ([_]Outcome{ .failed, .cancelled }) |outcome| {
        const id = state.begin(.manual, null, 0);
        state.settle(id, .{ .outcome = outcome }, 1);
        try std.testing.expect(state.snapshot.operation.?.visible(1_000_000));
        try std.testing.expect(!state.expire(id, state.snapshot.revision, 1_000_000));
        try std.testing.expect(state.dismiss(id, state.snapshot.revision));
    }
}

test "compaction activity failure retains error and publication provenance" {
    const uncertain = failure(error.SessionPersistenceUncertain, .publication, true);
    try std.testing.expectEqual(Outcome.failed, uncertain.outcome);
    try std.testing.expectEqual(Publication.uncertain, uncertain.publication);
    try std.testing.expectEqual(error.SessionPersistenceUncertain, uncertain.err.?);
    // A cooperative host can cancel transport before queued input sets the worker flag.
    try std.testing.expectEqual(Outcome.cancelled, failure(error.Cancelled, .summary, false).outcome);
    try std.testing.expectEqual(Outcome.cancelled, failure(error.Aborted, .publication, true).outcome);
    try std.testing.expectEqual(Outcome.failed, failure(error.Aborted, .publication, false).outcome);
    try std.testing.expectEqual(Outcome.failed, failure(error.ConnectionTimedOut, .summary, true).outcome);
}
