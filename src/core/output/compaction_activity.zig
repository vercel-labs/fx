const std = @import("std");
const compaction_progress = @import("compaction_progress.zig");

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
    /// `/compact` on a model whose provider writes the compaction block: the
    /// compaction runs right before the next message is sent, the one request
    /// fx can send to the provider exactly as before.
    scheduled: bool = false,
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
    /// The start of the activity row's own clock, whatever the origin.
    /// Manual admission resets it when queued.
    started_at_ms: i64,
    expires_at_ms: ?i64 = null,
    /// When the operation settled; 0 while it runs.
    settled_at_ms: i64 = 0,
    /// How far the summary has come: its requests' waits and its notes' count.
    progress: compaction_progress.Progress = .{},
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

    /// The number on the row: 0 while it prepares, the estimate of how far
    /// the summary has come while the model works on it, and 100 while fx
    /// saves it (`tests/tla/compaction_progress/CompactionProgress.tla`
    /// FullOnlyWhenSaving). Null when the row shows no number.
    pub fn percent(self: Operation) ?u8 {
        return switch (self.phase) {
            .preparing => 0,
            .running => |step| switch (step) {
                .preparation => 0,
                .summary => self.progress.shown(),
                .publication => 100,
            },
            .stopping, .terminal => null,
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

    /// A summary request is about to be sent; the row counts its wait from
    /// `now_ms`. Only for the operation still running.
    pub fn asked(self: *State, id: OperationId, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        op.progress.asked(now_ms);
        self.snapshot.revision += 1;
    }

    /// The UI's tick hands in the time, which moves the number while a
    /// summary request waits. It raises no revision, since the row's clock
    /// redraws it.
    pub fn observed(self: *State, now_ms: i64) void {
        const op = if (self.snapshot.operation) |*value| value else return;
        if (!op.active()) return;
        op.progress.observed(now_ms);
    }

    /// The notes' count rose. Only a higher count replaces a lower one, and
    /// only for the operation still running
    /// (`tests/tla/turn_clock/TurnClock.tla` CountNeverFalls,
    /// CountIsThisCompactions).
    pub fn written(self: *State, id: OperationId, percent: u8, now_ms: i64) void {
        const op = self.match(id) orelse return;
        if (!op.active()) return;
        if (!op.progress.written(percent, now_ms)) return;
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
        op.settled_at_ms = now_ms;
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

test "compaction activity records when an operation settled, once" {
    var state: State = .{};
    const id = state.begin(.manual, null, 1_000);
    try std.testing.expectEqual(@as(i64, 0), state.snapshot.operation.?.settled_at_ms);
    state.settle(id, .{ .outcome = .succeeded, .publication = .committed }, 131_000);
    try std.testing.expectEqual(@as(i64, 131_000), state.snapshot.operation.?.settled_at_ms);
    // A late settle of the same operation changes nothing.
    state.settle(id, failure(error.Cancelled, .summary, true), 140_000);
    try std.testing.expectEqual(@as(i64, 131_000), state.snapshot.operation.?.settled_at_ms);
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

test "the summary's count only goes up, and only for the compaction still running" {
    var state: State = .{};
    const first = state.begin(.manual, null, 1_000);
    state.running(first, .summary);
    state.written(first, 30, 1_000);
    state.written(first, 20, 1_000);
    try std.testing.expectEqual(@as(u8, 30), state.snapshot.operation.?.progress.notes);
    // A count that arrives after the compaction ended changes nothing.
    state.settle(first, .{ .outcome = .succeeded }, 2_000);
    state.written(first, 60, 2_000);
    try std.testing.expectEqual(@as(u8, 30), state.snapshot.operation.?.progress.notes);
    const second = state.begin(.automatic, 1, 3_000);
    // A new compaction starts at 0%, and a late count for the old one is
    // ignored.
    try std.testing.expectEqual(@as(u8, 0), state.snapshot.operation.?.progress.notes);
    state.written(first, 80, 3_000);
    try std.testing.expectEqual(@as(u8, 0), state.snapshot.operation.?.progress.notes);
    const revision = state.snapshot.revision;
    state.written(second, 0, 3_000);
    try std.testing.expectEqual(revision, state.snapshot.revision);
    // The count holds below 100 until fx has saved the summary.
    state.written(second, 100, 3_000);
    try std.testing.expectEqual(@as(u8, 99), state.snapshot.operation.?.progress.notes);
}

test "the row's number moves while a request waits and is 100 only while saving" {
    var state: State = .{};
    const id = state.begin(.manual, null, 1_000);
    state.observed(1_000);
    try std.testing.expectEqual(@as(?u8, 0), state.snapshot.operation.?.percent());
    state.running(id, .summary);
    state.asked(id, 1_000);
    try std.testing.expectEqual(@as(?u8, 0), state.snapshot.operation.?.percent());
    // The tick hands in the time. It moves the number and raises no revision.
    const revision = state.snapshot.revision;
    state.observed(54_000);
    try std.testing.expectEqual(@as(?u8, 23), state.snapshot.operation.?.percent());
    // A system clock set back takes nothing from the number.
    state.observed(2_000);
    try std.testing.expectEqual(@as(?u8, 23), state.snapshot.operation.?.percent());
    // A sleep, or a system clock set forward, adds nothing to it.
    state.observed(2_000 + 2 * std.time.ms_per_hour);
    try std.testing.expectEqual(@as(?u8, 23), state.snapshot.operation.?.percent());
    try std.testing.expectEqual(revision, state.snapshot.revision);
    state.written(id, 99, 126_000);
    try std.testing.expectEqual(@as(?u8, 99), state.snapshot.operation.?.percent());
    state.running(id, .publication);
    try std.testing.expectEqual(@as(?u8, 100), state.snapshot.operation.?.percent());
    state.stopping(id);
    try std.testing.expectEqual(@as(?u8, null), state.snapshot.operation.?.percent());
    // A request or a tick for a compaction that ended changes nothing.
    state.settle(id, .{ .outcome = .succeeded }, 127_000);
    const settled = state.snapshot.revision;
    const kept = state.snapshot.operation.?.progress;
    state.asked(id, 128_000);
    state.observed(900_000);
    try std.testing.expectEqual(settled, state.snapshot.revision);
    try std.testing.expectEqual(kept, state.snapshot.operation.?.progress);
}
