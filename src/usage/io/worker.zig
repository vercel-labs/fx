//! The one lazy worker per session ledger. It runs what the ledger core
//! (src/usage/core/ledger.zig) asks for and feeds every result back to the
//! core as an event, so the core's trace is the only record of what happened:
//!
//! - `start_lookup` → one `Host.Lookup.fetch` (`GET /v1/generation`), read
//!   with `receipt.classifyStatus` and `receipt.parseLookup`, then
//!   `lookup_found`, `lookup_unauthorized`, `lookup_rejected`, or
//!   `lookup_retry`.
//! - `publish_backlog` → one `Publisher.publish` per staged fact, then
//!   `publish` or `publish_conflict`; and one `publish_incident` per session
//!   incident, then `incident_published`.
//! - `publish_pending` → one `Publisher.publish_pending`.
//! - `persist_checkpoint` → `Host.SessionSink.persist`, before the step that
//!   asked for it returns. With `Markers`, the recovery marker is
//!   durable first whenever the checkpoint owes the profile ledger, and is
//!   cleared after one that owes nothing; `core/publish.zig` checks that
//!   order and traces it (machine `publication`).
//!
//! Concurrency:
//!
//! - **One task.** The worker is a single `std.Io.concurrent` task. It starts
//!   only when the core has lookup, publication, or checkpoint-retry work,
//!   and exits as soon as none is left; the next piece of work starts it
//!   again. Between attempts it sleeps on a futex with a deadline, so a
//!   backoff never spins.
//! - **Lock order: `checkpoint`, then `state`.** `checkpoint` serializes every
//!   core step and the persist that follows it, so checkpoints reach the sink
//!   in step order. `state` guards the core, the schedule, and the credential;
//!   it is held only for memory operations, never across I/O. The worker
//!   holds neither lock across `fetch` or `publish`, and takes `checkpoint`
//!   to pick its next job, so it never starts work whose checkpoint is still
//!   being written.
//! - **`close`** sets the cancel flag `fetch` honors, cancels the task, and
//!   joins it (the budget is 250 ms), then persists a last checkpoint
//!   if one is owed. Pending lookups and staged facts stay in that
//!   checkpoint, so nothing owed is lost.
//!
//! Credentials: the worker keeps the current secret in memory and the
//! core keeps only its SHA-256 digest. A 401/403 blocks the entry for that
//! digest only; `setCredential` with a different digest cancels a lookup in
//! flight and retries every waiting entry at once. An answer to a lookup sent
//! with a credential that has since changed is dropped, never applied. A
//! secret is never put in a checkpoint, a trace, or a log, and is zeroed when
//! replaced and at `close`.
//!
//! Retry schedule: the n-th retry of one
//! entry waits `first_ms * 2^((n-1)/2)`, capped at `max_ms`. With the
//! defaults (1 s, 60 s) the attempts after the first fall at 1, 2, 4, 6, 10,
//! 14, 22, 30, 46, ... s, so the Gateway's documented ingestion delay (404 for
//! about 20 s) is covered by 8 requests, and an entry that never appears
//! costs one request a minute. A new credential resets the schedule.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("../core/ledger.zig");
const host = @import("../host.zig");
const publication = @import("../core/publish.zig");
const receipt = @import("../receipt.zig");
const trace = @import("../trace.zig");

/// The largest `/v1/generation` body read, as fx's
/// `generation_response_max_bytes`.
pub const max_body_bytes = 128 * 1024;

/// Where staged facts go: the profile ledger (`usage.jsonl`). The module
/// owns that I/O; this is the seam between the worker and it.
pub const Publisher = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Appends `fact` to the profile ledger, or finds it already there.
        /// Durable when it returns. Must not retain `fact`.
        publish: *const fn (context: *anyopaque, fact: *const core.Fact) PublishError!Answer,
        /// Appends a waiting entry's `pending` record. Null keeps none.
        publish_pending: ?*const fn (context: *anyopaque, record: *const PendingRecord) PublishError!void = null,
        /// Appends one of the session's incidents. Null keeps them with the
        /// session (and its marker).
        publish_incident: ?*const fn (context: *anyopaque, incident: core.Incident) PublishError!void = null,
    };

    /// `conflict`: another variant of the generation holds the id, so the
    /// fact is never retried.
    pub const Answer = enum { appended, duplicate, conflict };

    pub const PendingRecord = struct {
        id: []const u8,
        observed_at_ms: i64,
    };

    pub const PublishError = error{
        /// The ledger lock is held elsewhere: try again later.
        Busy,
        /// Any other failure; the fact stays staged and is retried.
        Failed,
    };

    pub fn publish(publisher: Publisher, fact: *const core.Fact) PublishError!Answer {
        return publisher.vtable.publish(publisher.context, fact);
    }
};

/// The session's recovery marker (`io/markers.zig`). Without one the
/// worker persists checkpoints with no marker (unit tests, dev labs).
pub const Markers = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `markers.prepareCheckpoint`: when `input.next_owes`, the marker is
        /// durable when this returns. Returns the time to persist with the
        /// checkpoint, strictly after `input.saved_at_ms`.
        prepare: *const fn (context: *anyopaque, input: Input) Error!i64,
        /// `markers.finishCheckpoint` after a checkpoint that owes nothing.
        clear: *const fn (context: *anyopaque) Error!void,
    };

    pub const Input = struct {
        now_ms: i64,
        saved_at_ms: i64,
        saved_owes: bool,
        next_owes: bool,
    };

    pub const Error = error{MarkerFailed};
};

/// Persists checkpoints: the frozen ledger copy, handed over after the state
/// lock is released (`usage.zig` turns it into a `Checkpoint`).
pub const Sink = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Durable when it returns. Called with the checkpoint lock held, so
        /// checkpoints arrive one at a time, in order. Must not retain
        /// `checkpoint`.
        persist: *const fn (context: *anyopaque, checkpoint: *const Checkpoint) PersistError!void,
    };

    pub const PersistError = error{PersistFailed};

    pub fn persist(sink: Sink, checkpoint: *const Checkpoint) PersistError!void {
        return sink.vtable.persist(sink.context, checkpoint);
    }
};

/// What one checkpoint holds: a frozen copy of the session ledger, taken
/// under the state lock. It carries no credential and no digest:
/// `ledger.credential` is null, no digest is remembered, and blocked entries
/// read as waiting, since blocking is runtime-only.
pub const Checkpoint = struct {
    /// 1 for the first checkpoint of a worker, then one more each time.
    number: u64,
    /// Borrowed for the `persist` call only.
    ledger: *const core.Ledger,
    /// Wall-clock time to persist with it, strictly after the previous
    /// checkpoint's (the v2 `set usage` `at_ms`, the recovery marker's time).
    at_ms: i64,
    /// When this run opened the session; wall time is the saved
    /// `ledger.activity.wall_duration_ms` plus `at_ms - opened_at_ms`.
    opened_at_ms: i64,
};

/// A saved session to continue.
pub const Restore = struct {
    saved: core.Restored,
    /// The saved checkpoint's time (`markers.CheckpointInput.saved_at_ms`).
    saved_at_ms: i64,
    /// Whether the session's marker exists now.
    marker: bool,
};

/// Whether a checkpoint can still owe the profile ledger, as today's
/// `needsProfileRecovery`: anything staged, waiting, or unpublished, or a
/// call not settled through.
pub fn owes(ledger: *const core.Ledger) bool {
    return ledger.settled_through != ledger.next_sequence - 1 or
        ledger.waiting().len > 0 or
        ledger.staged().len > 0 or
        ledger.incidentList().len > 0;
}

/// Backoff for one entry's lookups, a fact's publication, or a failed
/// checkpoint. See the file comment for the default schedule.
pub const Schedule = struct {
    first_ms: u32 = 1_000,
    max_ms: u32 = 60_000,

    /// How long to wait before the `retry`-th retry (1-based).
    pub fn delayMs(schedule: Schedule, retry: u32) u32 {
        std.debug.assert(retry >= 1);
        const doublings: u6 = @intCast(@min((retry - 1) / 2, 32));
        const delay = @as(u64, schedule.first_ms) << doublings;
        return @intCast(@min(delay, schedule.max_ms));
    }

    /// A zero delay would retry without waiting.
    fn valid(schedule: Schedule) bool {
        return schedule.first_ms > 0 and schedule.max_ms >= schedule.first_ms;
    }
};

/// When the session's wall time starts counting in this run.
pub const WallStart = union(enum) {
    /// When the worker opens.
    open,
    /// At the first call, view, or checkpoint: a process's first session,
    /// which counts from when it is first used.
    first_use,
    /// At the session's creation, for a session resumed in this run: the
    /// saved wall time is replaced by the time since creation, and a session
    /// that predates usage accounting gets a complete wall time. A time
    /// that is not positive or is in the future makes it incomplete.
    at: i64,
};

pub const Options = struct {
    limits: core.Limits = .{},
    start: core.Start = .fresh,
    lookup: host.Lookup,
    sink: Sink,
    publisher: Publisher,
    markers: ?Markers = null,
    restore: ?Restore = null,
    /// A new session (no `restore`) whose marker is already on disk: an
    /// earlier run died before its first checkpoint was durable.
    existing_marker: bool = false,
    /// The core's trace instance (`core.Ledger.trace_instance`). Borrowed.
    trace_instance: []const u8 = "session",
    schedule: Schedule = .{},
    /// Core steps are traced here when trace code is compiled in. Written
    /// only under the checkpoint lock; the owner flushes it after `close`.
    tracer: ?*trace.Writer = null,
    /// Never start a task. The owner publishes with `publishOwed` after each
    /// report instead; lookups and checkpoint retries never run. For a
    /// ledger with no profile and no lookups, where the publisher is in
    /// memory, and for single-threaded hosts.
    inline_only: bool = false,
    wall_start: WallStart = .open,
};

/// What the worker has done, for tests and the dev lab.
pub const Stats = struct {
    /// Times the task started, exited because it had nothing left to do,
    /// or couldn't start.
    spawns: u32 = 0,
    idle_exits: u32 = 0,
    spawn_failures: u32 = 0,
    /// The most tasks ever running at once. Always at most 1.
    peak_tasks: u32 = 0,
    /// Lookups started, those refused for an untrusted origin, those canceled
    /// in flight, and answers dropped because the credential changed or the
    /// core no longer waited on them.
    lookups: u32 = 0,
    untrusted: u32 = 0,
    canceled: u32 = 0,
    stale_answers: u32 = 0,
    refused_answers: u32 = 0,
    publishes: u32 = 0,
    publish_failures: u32 = 0,
    conflicts: u32 = 0,
    pending_records: u32 = 0,
    incidents_published: u32 = 0,
    marker_failures: u32 = 0,
    persists: u32 = 0,
    persist_failures: u32 = 0,
    /// Sleeps until the next due job.
    waits: u32 = 0,
    trace_errors: u32 = 0,
    running: bool = false,
    scheduled_lookups: u32 = 0,
};

/// What a call reports. Lookup answers and publication results come from the
/// worker itself, and credentials through `setCredential`.
pub const CallEvent = union(enum) {
    begin: core.Provider,
    finish_exact: @FieldType(core.Event, "finish_exact"),
    finish_lookup: @FieldType(core.Event, "finish_lookup"),
    finish_unbilled: core.Sequence,
    finish_unpriced: @FieldType(core.Event, "finish_unpriced"),

    fn event(call: CallEvent) core.Event {
        return switch (call) {
            inline else => |payload, tag| @unionInit(core.Event, @tagName(tag), payload),
        };
    }
};

pub const InitError = core.Ledger.InitError || core.Ledger.RestoreError || error{ InvalidSchedule, TooManyStaged };

pub const ReportError = core.StepError || error{
    /// `close` has run.
    Closed,
    /// The step took effect but its checkpoint isn't durable. The worker
    /// retries it; a call that was about to send must not send.
    CheckpointFailed,
};

pub const CredentialError = host.Credential.Error || error{ Closed, CredentialOrdinalsExhausted };

pub const CloseError = error{
    /// The last checkpoint couldn't be written; the previous one stands.
    CheckpointFailed,
};

const Due = struct {
    due_ms: i64,
    retries: u32 = 0,
};

const Job = struct {
    sequence: core.Sequence,
    due: Due,
};

/// The current credential. Guarded by `state`.
const Held = struct {
    digest: ?core.Digest = null,
    /// Null for signed out and host-managed auth.
    secret_len: ?usize = null,
    secret: [host.Credential.max_secret_bytes]u8 = @splat(0),

    fn clear(held: *Held) void {
        std.crypto.secureZero(u8, &held.secret);
        held.* = .{};
    }

    fn set(held: *Held, credential: host.Credential, digest: ?core.Digest) void {
        held.clear();
        held.digest = digest;
        switch (credential) {
            .bearer => |secret| {
                @memcpy(held.secret[0..secret.len], secret);
                held.secret_len = secret.len;
            },
            .signed_out, .host_managed => {},
        }
    }
};

/// One lookup's request, copied out under `state` for the task to send.
/// Owned by the task.
const Outgoing = struct {
    sequence: core.Sequence = 0,
    id: core.GenerationId = undefined,
    digest: ?core.Digest = null,
    origin_len: usize = 0,
    origin: [core.max_origin_bytes]u8 = undefined,
    team_len: ?usize = null,
    team: [core.max_team_bytes]u8 = undefined,
    secret_len: ?usize = null,
    secret: [host.Credential.max_secret_bytes]u8 = @splat(0),

    fn originText(o: *const Outgoing) []const u8 {
        return o.origin[0..o.origin_len];
    }

    fn teamText(o: *const Outgoing) ?[]const u8 {
        return if (o.team_len) |len| o.team[0..len] else null;
    }

    fn secretText(o: *const Outgoing) ?[]const u8 {
        return if (o.secret_len) |len| o.secret[0..len] else null;
    }

    fn wipe(o: *Outgoing) void {
        std.crypto.secureZero(u8, &o.secret);
        o.secret_len = null;
    }
};

/// Why a step runs, which decides how its `start_lookup` effects are timed.
const Cause = enum {
    /// A call reported a finish: look up now.
    report,
    /// A different credential: look up now, from the start of the schedule.
    credential,
    /// A lookup said to ask again: wait out the next backoff.
    retry,
    /// Any other lookup answer or a publication result.
    answer,
};

const Next = union(enum) {
    exit,
    wait: struct { due_ms: i64, observed: u32 },
    lookup,
    publish,
    checkpoint,
};

/// What the task publishes next, copied out under `state`.
const Outbound = union(enum) {
    fact: core.Staged,
    pending: struct { sequence: core.Sequence, id: core.GenerationId, observed_at_ms: i64 },
    incident: core.Incident,
};

/// The worker for one session ledger. It owns the ledger core. Initialize in
/// place with `init`; it must not move until `deinit`, because its task
/// points at it. Every method is safe to call from any thread, except
/// `deinit`, which must come after `close`.
pub const Worker = struct {
    io: Io,
    /// Thread-safe: the task allocates with it while parsing a lookup body.
    gpa: Allocator,
    lookup: host.Lookup,
    sink: Sink,
    publisher: Publisher,
    markers: ?Markers,
    schedule: Schedule,
    tracer: ?*trace.Writer,
    inline_only: bool,
    /// Wall-clock time this run's wall time counts from. Guarded by `state`
    /// while `wall_waiting`.
    opened_at_ms: i64,
    /// `WallStart.first_use` and nothing has used the session yet.
    wall_waiting: bool = false,

    checkpoint: Io.Mutex = .init,
    state: Io.Mutex = .init,

    // Guarded by `state`.
    ledger: core.Ledger,
    held: Held = .{},
    jobs: [core.Limits.ceiling]Job = undefined,
    job_count: usize = 0,
    /// Waiting entries whose `pending` record isn't published yet.
    pending_records: [core.Limits.ceiling]core.Sequence = undefined,
    pending_record_count: usize = 0,
    publish_due: ?Due = null,
    /// Activity changed since the last checkpoint.
    activity_dirty: bool = false,
    /// A step's checkpoint failed; `checkpoint_due` says when to try again.
    dirty: bool = false,
    checkpoint_due: ?Due = null,
    running: bool = false,
    closing: bool = false,
    /// The lookup being sent, and the credential it was sent with.
    in_flight: ?struct { sequence: core.Sequence, digest: ?core.Digest } = null,
    counters: Stats = .{},

    // Guarded by `checkpoint`.
    frozen: core.Ledger,
    checkpoint_number: u64 = 0,
    task: ?Io.Future(void) = null,
    publication: publication.Machine = .{},
    saved_at_ms: i64 = 0,
    saved_owes: bool = false,

    // Owned by the task.
    outgoing: Outgoing = .{},
    outbound: Outbound = undefined,
    body: []u8,

    /// Bumped (and woken) when new work arrives or `close` runs.
    wake: std.atomic.Value(u32) = .init(0),
    /// Set when the lookup in flight must stop: at `close`, or when the
    /// credential it was sent with changes.
    cancel: std.atomic.Value(bool) = .init(false),
    tasks: std.atomic.Value(u32) = .init(0),

    /// Allocates the core, its checkpoint copy, and the body buffer with
    /// `gpa`. Starts nothing.
    pub fn init(w: *Worker, gpa: Allocator, io: Io, options: Options) InitError!void {
        if (!options.schedule.valid()) return error.InvalidSchedule;
        var ledger = try core.Ledger.init(gpa, options.limits, options.start);
        errdefer ledger.deinit(gpa);
        var frozen = try core.Ledger.init(gpa, options.limits, options.start);
        errdefer frozen.deinit(gpa);
        ledger.trace_instance = options.trace_instance;
        frozen.trace_instance = options.trace_instance;
        const body = try gpa.alloc(u8, max_body_bytes);
        errdefer gpa.free(body);
        w.* = .{
            .io = io,
            .gpa = gpa,
            .lookup = options.lookup,
            .sink = options.sink,
            .publisher = options.publisher,
            .markers = options.markers,
            .schedule = options.schedule,
            .tracer = options.tracer,
            .inline_only = options.inline_only,
            .opened_at_ms = wallMs(io),
            .wall_waiting = options.wall_start == .first_use,
            .ledger = ledger,
            .frozen = frozen,
            .body = body,
        };
        var marker = options.existing_marker;
        if (options.restore) |saved| {
            var out: core.Output = .{};
            try w.ledger.restore(saved.saved, &out, w.tracer);
            _ = w.afterStepLocked(&out, .answer);
            w.startWallAt(options.wall_start, true);
            freeze(&w.frozen, &w.ledger);
            w.saved_at_ms = saved.saved_at_ms;
            w.saved_owes = owes(&w.frozen);
            marker = saved.marker;
        } else {
            w.startWallAt(options.wall_start, false);
            freeze(&w.frozen, &w.ledger);
            if (!marker) return;
        }
        // A later run of the session: the publication machine starts from
        // what is durable.
        if (w.markers != null) {
            var staged: [core.Limits.ceiling]core.Sequence = undefined;
            const projection = projectionOf(&w.frozen, &staged);
            w.publication.step(.{ .restart = .{ .saved = projection, .marker = marker } }, w.tracer) catch |err| switch (err) {
                error.TooManyStaged => return error.TooManyStaged,
                else => w.counters.trace_errors += 1,
            };
        }
    }

    fn startWallAt(w: *Worker, wall_start: WallStart, restored: bool) void {
        const created_at_ms = switch (wall_start) {
            .open, .first_use => return,
            .at => |at_ms| at_ms,
        };
        const activity = &w.ledger.activity;
        if (created_at_ms <= 0 or created_at_ms > w.opened_at_ms) {
            activity.wall_duration_complete = false;
            return;
        }
        w.opened_at_ms = created_at_ms;
        activity.wall_duration_ms = 0;
        if (!restored) activity.wall_duration_complete = true;
    }

    /// Under `state`.
    fn useWallLocked(w: *Worker) void {
        if (!w.wall_waiting) return;
        w.wall_waiting = false;
        w.opened_at_ms = wallMs(w.io);
    }

    /// When this run's wall time counts from; for `first_use`, using the
    /// session starts it.
    pub fn openedAt(w: *Worker) i64 {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.useWallLocked();
        return w.opened_at_ms;
    }

    /// Starts the work a restored session brought: lookups once a credential
    /// arrives, and publishing its backlog, incidents, and pending records.
    pub fn start(w: *Worker) void {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        w.kick();
    }

    /// Adds activity the host measured. It is persisted with the next
    /// checkpoint, or at `close`.
    pub fn recordActivity(w: *Worker, delta: core.ActivityDelta) void {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.ledger.recordActivity(delta);
        w.activity_dirty = true;
    }

    /// Persists a checkpoint now if activity changed since the last one, so
    /// activity the host measured is durable before it goes on.
    pub fn flushActivity(w: *Worker) error{ Closed, CheckpointFailed }!void {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (w.closing) return error.Closed;
            if (!w.activity_dirty) return;
            freeze(&w.frozen, &w.ledger);
            w.activity_dirty = false;
        }
        try w.persistFrozen();
    }

    /// For a host that exits right after its last call: waits up to
    /// `budget_ms` while a lookup is in flight or due now, so a generation
    /// the Gateway has already priced settles before `close`. Entries that
    /// back off, or wait for a credential, stay for the next run.
    pub fn awaitLookups(w: *Worker, budget_ms: u32) void {
        const deadline = w.nowMs() +| budget_ms;
        while (true) {
            const busy = blk: {
                w.state.lockUncancelable(w.io);
                defer w.state.unlock(w.io);
                if (w.closing or w.inline_only) return;
                if (w.in_flight != null) break :blk true;
                if (w.ledger.credential == null) return;
                const now = w.nowMs();
                for (w.jobs[0..w.job_count]) |job| {
                    if (job.due.due_ms <= now) break :blk true;
                }
                break :blk false;
            };
            if (!busy or w.nowMs() >= deadline) return;
            w.io.sleep(.fromMilliseconds(2), .awake) catch return;
        }
    }

    /// Copies the session ledger into `dst` (same limits), scrubbed as a
    /// checkpoint is, for views that need more than `view` returns.
    pub fn copyLedger(w: *Worker, dst: *core.Ledger) void {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.useWallLocked();
        freeze(dst, &w.ledger);
    }

    /// After `close`.
    pub fn deinit(w: *Worker) void {
        std.debug.assert(w.closing and w.task == null);
        w.held.clear();
        w.outgoing.wipe();
        w.ledger.deinit(w.gpa);
        w.frozen.deinit(w.gpa);
        w.gpa.free(w.body);
        w.* = undefined;
    }

    /// Reports one call event and returns its transition (for `begin`, the
    /// new call's sequence). When the step needs a checkpoint, it is durable
    /// before this returns. A refused event changes nothing.
    pub fn report(w: *Worker, call: CallEvent) ReportError!core.Transition {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        var out: core.Output = .{};
        const persist = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (w.closing) return error.Closed;
            w.useWallLocked();
            try w.ledger.step(call.event(), &out, w.tracer);
            break :blk w.afterStepLocked(&out, .report);
        };
        const result = if (persist) w.persistFrozen() else {};
        if (result) |_| {} else |_| if (call == .begin) w.endUnsentLocked(out.transition.?.call);
        w.kick();
        try result;
        return out.transition.?;
    }

    /// A begin whose checkpoint failed never sends, so the call ends unbilled
    /// at once instead of staying in flight. Caller holds `checkpoint`.
    fn endUnsentLocked(w: *Worker, sequence: core.Sequence) void {
        var out: core.Output = .{};
        const persist = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.ledger.step(.{ .finish_unbilled = sequence }, &out, w.tracer) catch break :blk false;
            break :blk w.afterStepLocked(&out, .report);
        };
        if (persist) w.persistFrozen() catch {};
    }

    /// The host's credential changed. A different credential cancels a
    /// lookup in flight that was sent with the old one, and every waiting
    /// entry it didn't block is looked up at once.
    pub fn setCredential(w: *Worker, credential: host.Credential) CredentialError!void {
        const digest = try credential.digest();
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (w.closing) return error.Closed;
            var out: core.Output = .{};
            w.ledger.step(.{ .set_credential = digest }, &out, w.tracer) catch |err| switch (err) {
                error.CredentialOrdinalsExhausted => return error.CredentialOrdinalsExhausted,
                else => unreachable, // set_credential refuses nothing else
            };
            w.held.set(credential, digest);
            if (w.in_flight) |flight| {
                if (!sameDigest(flight.digest, digest)) w.cancel.store(true, .release);
            }
            const persist = w.afterStepLocked(&out, .credential);
            // set_credential never asks for a checkpoint: blocking is runtime-only.
            std.debug.assert(!persist);
        }
        w.kick();
    }

    /// The session view, with model rows copied into `rows` (truncated to
    /// its length), so the view stays valid after the lock is released.
    pub fn view(w: *Worker, rows: []core.ModelRow) core.View {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        var v = w.ledger.view();
        const count = @min(rows.len, v.models.len);
        @memcpy(rows[0..count], v.models[0..count]);
        v.models = rows[0..count];
        return v;
    }

    pub fn stats(w: *Worker) Stats {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        var s = w.counters;
        s.running = w.running;
        s.scheduled_lookups = @intCast(w.job_count);
        return s;
    }

    /// Cancels the lookup in flight, joins the task, and persists a last
    /// checkpoint if one is owed. Later calls do nothing. After this,
    /// `report` and `setCredential` return `error.Closed`.
    pub fn close(w: *Worker) CloseError!void {
        var task: ?Io.Future(void) = null;
        {
            w.checkpoint.lockUncancelable(w.io);
            defer w.checkpoint.unlock(w.io);
            w.state.lockUncancelable(w.io);
            w.closing = true;
            w.cancel.store(true, .release);
            w.ring();
            w.state.unlock(w.io);
            task = w.task;
            w.task = null;
        }
        // Neither lock is held: the task may need both to finish its step.
        if (task) |*running| running.cancel(w.io);
        w.publishOwed();

        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        const owed = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.held.clear();
            const due = w.dirty or w.activity_dirty;
            if (due) freeze(&w.frozen, &w.ledger);
            break :blk due;
        };
        if (owed) return w.persistFrozen();
        // A marker whose clear failed earlier, for a checkpoint that owes nothing.
        if (w.markers) |markers| if (w.publication.marker and !w.saved_owes) w.clearMarker(markers);
    }

    /// One attempt for each item owed now, in the task's order: the bounded
    /// final publish at `close` (with the task joined), and every publish of
    /// an `inline_only` worker. The first failure stops it; what is left
    /// stays in the checkpoint and under the marker for the next run.
    /// Lookups are not attempted. No task may be running.
    pub fn publishOwed(w: *Worker) void {
        var attempts = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            const incidents = if (w.publisher.vtable.publish_incident != null) w.ledger.incidentList().len else 0;
            break :blk w.ledger.staged().len + w.pending_record_count + incidents;
        };
        while (attempts > 0) : (attempts -= 1) {
            const failures = blk: {
                w.state.lockUncancelable(w.io);
                defer w.state.unlock(w.io);
                w.prunePendingRecordsLocked();
                if (!w.hasPublicationLocked()) return;
                w.outbound = w.nextOutboundLocked();
                break :blk w.counters.publish_failures;
            };
            w.runPublish();
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (w.counters.publish_failures != failures) return;
        }
    }

    // Steps and scheduling ----------------------------------------------------

    /// After a successful core step, under `state`: updates the schedule from
    /// the step's effects and freezes a checkpoint when one is needed.
    /// Returns whether the caller must persist it (with `checkpoint` held).
    fn afterStepLocked(w: *Worker, out: *const core.Output, cause: Cause) bool {
        if (out.trace_error != null) w.counters.trace_errors += 1;
        w.pruneJobsLocked();
        const now = w.nowMs();
        var persist = false;
        for (out.effects()) |effect| switch (effect) {
            .persist_checkpoint => persist = true,
            .start_lookup => |sequence| w.planLookupLocked(sequence, cause, now),
            .publish_backlog => if (w.publish_due == null) {
                w.publish_due = .{ .due_ms = now };
            },
            .publish_pending => |sequence| {
                const queued = std.mem.indexOfScalar(core.Sequence, w.pending_records[0..w.pending_record_count], sequence) != null;
                // At most max_pending entries wait, and max_pending <= ceiling.
                if (!queued and w.pending_record_count < w.pending_records.len) {
                    w.pending_records[w.pending_record_count] = sequence;
                    w.pending_record_count += 1;
                }
                if (w.publish_due == null) w.publish_due = .{ .due_ms = now };
            },
        };
        if (persist) {
            freeze(&w.frozen, &w.ledger);
            w.activity_dirty = false;
        }
        return persist;
    }

    /// Drops jobs for entries that no longer wait in `lookup`, and every job
    /// while no credential is held (lookups need one).
    fn pruneJobsLocked(w: *Worker) void {
        var kept: usize = 0;
        for (w.jobs[0..w.job_count]) |job| {
            if (w.ledger.credential == null) continue;
            const waiting = for (w.ledger.waiting()) |entry| {
                if (entry.sequence == job.sequence) break entry.status == .lookup;
            } else false;
            if (!waiting) continue;
            w.jobs[kept] = job;
            kept += 1;
        }
        w.job_count = kept;
    }

    fn planLookupLocked(w: *Worker, sequence: core.Sequence, cause: Cause, now: i64) void {
        const index = for (w.jobs[0..w.job_count], 0..) |job, i| {
            if (job.sequence == sequence) break i;
        } else blk: {
            // At most max_pending entries wait, and max_pending <= ceiling.
            std.debug.assert(w.job_count < w.jobs.len);
            w.jobs[w.job_count] = .{ .sequence = sequence, .due = .{ .due_ms = now } };
            w.job_count += 1;
            break :blk w.job_count - 1;
        };
        const job = &w.jobs[index];
        job.due = switch (cause) {
            .retry => w.later(job.due.retries, now),
            .report, .credential, .answer => .{ .due_ms = now },
        };
    }

    /// The next backoff after `retries` retries.
    fn later(w: *const Worker, retries: u32, now: i64) Due {
        const retry = retries +| 1;
        return .{ .due_ms = now + w.schedule.delayMs(retry), .retries = retry };
    }

    /// Persists the frozen checkpoint. Caller holds `checkpoint`. Shielded
    /// from task cancelation, so a `close` never interrupts a write.
    fn persistFrozen(w: *Worker) error{CheckpointFailed}!void {
        const protection = w.io.swapCancelProtection(.blocked);
        defer _ = w.io.swapCancelProtection(protection);
        var staged: [core.Limits.ceiling]core.Sequence = undefined;
        const projection = projectionOf(&w.frozen, &staged);
        const now = wallMs(w.io);
        var at_ms = if (now > w.saved_at_ms) now else w.saved_at_ms +| 1;
        var plan: publication.Plan = .{ .write_marker = false, .clear_marker = false };
        if (w.markers) |markers| {
            plan = w.publication.checkpoint(projection);
            // Called for every checkpoint: it also picks the checkpoint's time.
            at_ms = markers.vtable.prepare(markers.context, .{
                .now_ms = now,
                .saved_at_ms = w.saved_at_ms,
                .saved_owes = w.saved_owes,
                .next_owes = projection.owes,
            }) catch return w.persistFailed(true);
            if (plan.write_marker) w.tracePublication(.marker_written);
        }
        w.checkpoint_number += 1;
        const checkpoint: Checkpoint = .{
            .number = w.checkpoint_number,
            .ledger = &w.frozen,
            .at_ms = at_ms,
            .opened_at_ms = w.openedAt(),
        };
        w.sink.persist(&checkpoint) catch return w.persistFailed(false);
        w.saved_at_ms = at_ms;
        w.saved_owes = projection.owes;
        if (w.markers) |markers| {
            w.tracePublication(.{ .persisted = projection });
            if (plan.clear_marker) w.clearMarker(markers);
        }
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.counters.persists += 1;
        w.dirty = false;
        w.checkpoint_due = null;
    }

    fn persistFailed(w: *Worker, marker: bool) error{CheckpointFailed} {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        if (marker) w.counters.marker_failures += 1 else w.counters.persist_failures += 1;
        const retries = if (w.checkpoint_due) |due| due.retries else 0;
        w.dirty = true;
        w.checkpoint_due = w.later(retries, w.nowMs());
        return error.CheckpointFailed;
    }

    /// Caller holds `checkpoint`. A failed clear leaves the marker; the
    /// next checkpoint that owes nothing, or `close`, tries again.
    fn clearMarker(w: *Worker, markers: Markers) void {
        markers.vtable.clear(markers.context) catch {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.counters.marker_failures += 1;
            return;
        };
        w.tracePublication(.marker_cleared);
    }

    /// Steps the publication machine. Caller holds `checkpoint`. A refusal
    /// here is a worker bug the machine caught; it is counted, not hidden.
    fn tracePublication(w: *Worker, event: publication.Event) void {
        w.publication.step(event, w.tracer) catch {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.counters.trace_errors += 1;
        };
    }

    /// Whether anything is due now or later. Under `state`.
    fn hasWorkLocked(w: *const Worker) bool {
        if (w.job_count > 0) return true;
        if (w.publish_due != null and w.hasPublicationLocked()) return true;
        return w.dirty;
    }

    fn hasPublicationLocked(w: *const Worker) bool {
        return w.ledger.staged().len > 0 or w.pending_record_count > 0 or
            (w.publisher.vtable.publish_incident != null and w.ledger.incidentList().len > 0);
    }

    /// Starts the task if there is work and it isn't running, else wakes it.
    /// Caller holds `checkpoint`, which serializes starts.
    fn kick(w: *Worker) void {
        {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (w.closing or w.inline_only or !w.hasWorkLocked()) return;
            if (w.running) {
                w.ring();
                return;
            }
            w.running = true;
        }
        // The last task cleared `running` as its final step, so this returns
        // as soon as it has.
        if (w.task) |*done| done.await(w.io);
        w.task = w.io.concurrent(run, .{w}) catch {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.running = false;
            w.counters.spawn_failures += 1;
            return;
        };
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.counters.spawns += 1;
    }

    fn ring(w: *Worker) void {
        _ = w.wake.fetchAdd(1, .release);
        w.io.futexWake(u32, &w.wake.raw, 1);
    }

    fn nowMs(w: *const Worker) i64 {
        return Io.Clock.Timestamp.now(w.io, .awake).raw.toMilliseconds();
    }

    // The task ----------------------------------------------------------------

    fn run(w: *Worker) void {
        const active = w.tasks.fetchAdd(1, .acq_rel) + 1;
        defer _ = w.tasks.fetchSub(1, .acq_rel);
        {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.counters.peak_tasks = @max(w.counters.peak_tasks, active);
        }
        while (true) {
            switch (w.next()) {
                .exit => return,
                .wait => |wait| {
                    const deadline: Io.Clock.Timestamp = .{
                        .raw = .fromNanoseconds(@as(i96, wait.due_ms) * std.time.ns_per_ms),
                        .clock = .awake,
                    };
                    w.io.futexWaitTimeout(u32, &w.wake.raw, wait.observed, .{ .deadline = deadline }) catch {
                        // Canceled: only `close` cancels the task.
                        w.stop();
                        return;
                    };
                },
                .lookup => w.runLookup() catch {
                    w.stop();
                    return;
                },
                .publish => w.runPublish(),
                .checkpoint => w.runCheckpoint(),
            }
        }
    }

    fn stop(w: *Worker) void {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        w.running = false;
    }

    /// Picks the earliest job. Takes `checkpoint` first, so a step's
    /// checkpoint is durable before any work it scheduled starts.
    fn next(w: *Worker) Next {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        if (w.closing) {
            w.running = false;
            return .exit;
        }
        w.prunePendingRecordsLocked();
        if (w.publish_due != null and !w.hasPublicationLocked()) w.publish_due = null;
        w.pruneJobsLocked();

        const Pick = struct { due_ms: i64, what: enum { lookup, publish, checkpoint }, index: usize = 0 };
        var pick: ?Pick = null;
        if (w.dirty) {
            const due = w.checkpoint_due.?;
            pick = .{ .due_ms = due.due_ms, .what = .checkpoint };
        } else if (w.publish_due) |due| {
            // A fact publishes only once its checkpoint is durable.
            pick = .{ .due_ms = due.due_ms, .what = .publish };
        }
        for (w.jobs[0..w.job_count], 0..) |job, index| {
            if (pick == null or job.due.due_ms < pick.?.due_ms) pick = .{ .due_ms = job.due.due_ms, .what = .lookup, .index = index };
        }
        const chosen = pick orelse {
            w.running = false;
            w.counters.idle_exits += 1;
            return .exit;
        };
        if (chosen.due_ms > w.nowMs()) {
            w.counters.waits += 1;
            return .{ .wait = .{ .due_ms = chosen.due_ms, .observed = w.wake.load(.acquire) } };
        }
        switch (chosen.what) {
            .checkpoint => return .checkpoint,
            .publish => {
                w.outbound = w.nextOutboundLocked();
                return .publish;
            },
            .lookup => {
                w.prepareLookupLocked(w.jobs[chosen.index].sequence);
                return .lookup;
            },
        }
    }

    /// Drops the pending records of entries that no longer wait: a lookup
    /// resolved before its record was published, so the record isn't needed.
    /// Under `state`, before `hasPublicationLocked` decides.
    fn prunePendingRecordsLocked(w: *Worker) void {
        var kept: usize = 0;
        for (w.pending_records[0..w.pending_record_count]) |sequence| {
            const waits = for (w.ledger.waiting()) |entry| {
                if (entry.sequence == sequence) break true;
            } else false;
            if (!waits) continue;
            w.pending_records[kept] = sequence;
            kept += 1;
        }
        w.pending_record_count = kept;
    }

    /// Pending records first, then incidents, then staged facts: the order
    /// today's flush publishes them in. Under `state`, right after
    /// `prunePendingRecordsLocked` and a true `hasPublicationLocked`.
    fn nextOutboundLocked(w: *Worker) Outbound {
        if (w.pending_record_count > 0) {
            const sequence = w.pending_records[0];
            for (w.ledger.waiting()) |entry| {
                if (entry.sequence == sequence) return .{ .pending = .{ .sequence = sequence, .id = entry.id, .observed_at_ms = entry.observed_at_ms } };
            }
        }
        if (w.publisher.vtable.publish_incident != null and w.ledger.incidentList().len > 0) {
            return .{ .incident = w.ledger.incidentList()[0] };
        }
        return .{ .fact = w.ledger.staged()[0] };
    }

    fn dropPendingRecordLocked(w: *Worker, sequence: core.Sequence) void {
        const index = std.mem.indexOfScalar(core.Sequence, w.pending_records[0..w.pending_record_count], sequence) orelse return;
        std.mem.copyForwards(core.Sequence, w.pending_records[index .. w.pending_record_count - 1], w.pending_records[index + 1 .. w.pending_record_count]);
        w.pending_record_count -= 1;
    }

    /// Copies one entry's request and the credential for the task.
    fn prepareLookupLocked(w: *Worker, sequence: core.Sequence) void {
        const entry = for (w.ledger.waiting()) |*entry| {
            if (entry.sequence == sequence) break entry;
        } else unreachable; // pruneJobsLocked keeps only waiting entries
        const o = &w.outgoing;
        o.wipe();
        o.sequence = sequence;
        o.id = entry.id;
        o.digest = w.held.digest;
        const origin = entry.originText();
        @memcpy(o.origin[0..origin.len], origin);
        o.origin_len = origin.len;
        o.team_len = null;
        if (entry.teamText()) |team| {
            @memcpy(o.team[0..team.len], team);
            o.team_len = team.len;
        }
        if (w.held.secret_len) |len| {
            @memcpy(o.secret[0..len], w.held.secret[0..len]);
            o.secret_len = len;
        }
        w.in_flight = .{ .sequence = sequence, .digest = w.held.digest };
        w.cancel.store(false, .release);
        w.counters.lookups += 1;
    }

    /// Sends one lookup and applies its answer. Returns `error.Canceled`
    /// only when `close` stopped it.
    fn runLookup(w: *Worker) error{Canceled}!void {
        const o = &w.outgoing;
        defer o.wipe();
        if (!w.lookup.trusted(o.originText())) {
            w.countLocked(.untrusted);
            return w.answer(.{ .lookup_rejected = o.sequence }, .answer);
        }
        const request: host.Lookup.Request = .{
            .origin = o.originText(),
            .generation_id = o.id.slice(),
            .team = o.teamText(),
            .secret = o.secretText(),
            .cancel = &w.cancel,
        };
        const response = w.lookup.fetch(&request, w.body) catch |err| switch (err) {
            error.Canceled => {
                const asked = blk: {
                    w.state.lockUncancelable(w.io);
                    defer w.state.unlock(w.io);
                    if (w.closing) {
                        w.counters.canceled += 1;
                        return error.Canceled;
                    }
                    if (!w.cancel.load(.acquire)) break :blk false;
                    // The credential changed: setCredential already rescheduled.
                    w.in_flight = null;
                    w.counters.canceled += 1;
                    break :blk true;
                };
                if (asked) return;
                // A cancel nobody asked for: back off as for a transport
                // failure, so a host that keeps doing it can't make us spin.
                return w.answer(.{ .lookup_retry = o.sequence }, .retry);
            },
            error.Transport, error.BodyTooLarge => return w.answer(.{ .lookup_retry = o.sequence }, .retry),
        };
        const status = std.math.cast(u10, response.status) orelse
            return w.answer(.{ .lookup_retry = o.sequence }, .retry);
        switch (receipt.classifyStatus(@enumFromInt(status))) {
            .retry => return w.answer(.{ .lookup_retry = o.sequence }, .retry),
            .unauthorized => return w.answer(.{ .lookup_unauthorized = o.sequence }, .answer),
            .rejected => return w.answer(.{ .lookup_rejected = o.sequence }, .answer),
            .found_or_parse => {},
        }
        var record = receipt.parseLookup(w.gpa, w.body[0..response.body_len], o.id.slice()) catch |err| switch (err) {
            // Our own memory, not the answer: ask again later.
            error.OutOfMemory => return w.answer(.{ .lookup_retry = o.sequence }, .retry),
            else => return w.answer(.{ .lookup_rejected = o.sequence }, .answer),
        };
        defer record.deinit(w.gpa);
        const id = core.GenerationId.parse(record.id) catch
            return w.answer(.{ .lookup_rejected = o.sequence }, .answer);
        return w.answer(.{ .lookup_found = .{ .sequence = o.sequence, .fact = .{
            .id = id,
            .created_at_ms = record.created_at_ms,
            .model = record.model,
            .total_cost = record.total_cost,
            .input_tokens = record.input_tokens,
            .output_tokens = record.output_tokens,
            .cache_read_tokens = record.cache_read_tokens,
            .cache_write_tokens = record.cache_write_tokens,
            .reasoning_tokens = record.reasoning_tokens,
            .billable_web_search_calls = record.billable_web_search_calls,
        } } }, .answer);
    }

    fn countLocked(w: *Worker, comptime field: enum { untrusted }) void {
        w.state.lockUncancelable(w.io);
        defer w.state.unlock(w.io);
        @field(w.counters, @tagName(field)) += 1;
    }

    /// Applies a lookup answer, unless the credential it was sent with has
    /// changed. A found fact the core can't take (invalid, mismatched, or a
    /// duplicate id) becomes a rejection, so it is counted and visible.
    fn answer(w: *Worker, event: core.Event, cause: Cause) void {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        var out: core.Output = .{};
        const persist = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            const sent_with = if (w.in_flight) |flight| flight.digest else w.outgoing.digest;
            w.in_flight = null;
            if (!sameDigest(sent_with, w.held.digest)) {
                w.counters.stale_answers += 1;
                w.pruneJobsLocked();
                return;
            }
            w.ledger.step(event, &out, w.tracer) catch |err| {
                const fallback: ?core.Event = switch (err) {
                    error.NotLookingUp, error.NoCredential => null,
                    else => if (event == .lookup_found) .{ .lookup_rejected = event.lookup_found.sequence } else null,
                };
                if (fallback) |rejected| if (w.ledger.step(rejected, &out, w.tracer)) |_| {
                    break :blk w.afterStepLocked(&out, .answer);
                } else |_| {};
                w.counters.refused_answers += 1;
                w.pruneJobsLocked();
                return;
            };
            break :blk w.afterStepLocked(&out, cause);
        };
        // A failed checkpoint is retried by the task; nothing to report here.
        if (persist) w.persistFrozen() catch {};
    }

    fn runPublish(w: *Worker) void {
        const protection = w.io.swapCancelProtection(.blocked);
        defer _ = w.io.swapCancelProtection(protection);
        switch (w.outbound) {
            .fact => |*staged| w.publishFact(staged),
            .pending => |pending| {
                const record: Publisher.PendingRecord = .{ .id = pending.id.slice(), .observed_at_ms = pending.observed_at_ms };
                const result = if (w.publisher.vtable.publish_pending) |f| f(w.publisher.context, &record) else {};
                w.state.lockUncancelable(w.io);
                defer w.state.unlock(w.io);
                result catch return w.publishFailedLocked();
                w.counters.pending_records += 1;
                w.dropPendingRecordLocked(pending.sequence);
                w.publish_due = .{ .due_ms = w.nowMs() };
            },
            .incident => |incident| {
                const f = w.publisher.vtable.publish_incident.?;
                f(w.publisher.context, incident) catch {
                    w.state.lockUncancelable(w.io);
                    defer w.state.unlock(w.io);
                    return w.publishFailedLocked();
                };
                w.checkpoint.lockUncancelable(w.io);
                defer w.checkpoint.unlock(w.io);
                var out: core.Output = .{};
                const persist = blk: {
                    w.state.lockUncancelable(w.io);
                    defer w.state.unlock(w.io);
                    w.counters.incidents_published += 1;
                    w.publish_due = .{ .due_ms = w.nowMs() };
                    w.ledger.step(.{ .incident_published = incident }, &out, w.tracer) catch break :blk false;
                    break :blk w.afterStepLocked(&out, .answer);
                };
                if (persist) w.persistFrozen() catch {};
            },
        }
    }

    /// Under `state`.
    fn publishFailedLocked(w: *Worker) void {
        w.counters.publish_failures += 1;
        const retries = if (w.publish_due) |due| due.retries else 0;
        w.publish_due = w.later(retries, w.nowMs());
    }

    fn publishFact(w: *Worker, staged: *const core.Staged) void {
        const fact = staged.fact();
        const reply = w.publisher.publish(&fact) catch {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            return w.publishFailedLocked();
        };
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        if (w.markers != null) w.tracePublication(switch (reply) {
            .appended, .duplicate => .{ .appended = staged.sequence },
            .conflict => .{ .conflict = staged.sequence },
        });
        var out: core.Output = .{};
        const persist = blk: {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            w.counters.publishes += 1;
            const event: core.Event = switch (reply) {
                .appended => .{ .publish = .{ .sequence = staged.sequence, .result = .appended } },
                .duplicate => .{ .publish = .{ .sequence = staged.sequence, .result = .duplicate } },
                .conflict => .{ .publish_conflict = staged.sequence },
            };
            if (reply == .conflict) w.counters.conflicts += 1;
            w.ledger.step(event, &out, w.tracer) catch {
                w.counters.refused_answers += 1;
                break :blk false;
            };
            // Keep draining while anything remains to publish.
            w.publish_due = if (w.hasPublicationLocked()) .{ .due_ms = w.nowMs() } else null;
            break :blk w.afterStepLocked(&out, .answer);
        };
        if (persist) {
            if (w.markers != null and reply != .conflict) w.tracePublication(.{ .settled = staged.sequence });
            w.persistFrozen() catch {};
        }
    }

    fn runCheckpoint(w: *Worker) void {
        w.checkpoint.lockUncancelable(w.io);
        defer w.checkpoint.unlock(w.io);
        {
            w.state.lockUncancelable(w.io);
            defer w.state.unlock(w.io);
            if (!w.dirty) return;
            freeze(&w.frozen, &w.ledger);
        }
        w.persistFrozen() catch {};
    }
};

fn wallMs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

/// The publication machine's view of a checkpoint.
fn projectionOf(ledger: *const core.Ledger, buffer: *[core.Limits.ceiling]core.Sequence) publication.Projection {
    const staged = ledger.staged();
    for (staged, 0..) |entry, index| buffer[index] = entry.sequence;
    return .{ .staged = buffer[0..staged.len], .owes = owes(ledger) };
}

fn sameDigest(a: ?core.Digest, b: ?core.Digest) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, &x, &y);
}

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

/// Copies `src` into `dst`, which has the same limits, without allocating,
/// then removes everything a checkpoint must not carry: the credential, the
/// digests remembered for trace ordinals, and which credential blocked an
/// entry (`Checkpoint`).
fn freeze(dst: *core.Ledger, src: *const core.Ledger) void {
    inline for (std.meta.fields(core.Ledger)) |field| {
        if (comptime isList(field.type)) {
            const from = @field(src, field.name).items;
            const to = &@field(dst, field.name);
            // Both were allocated with the same limits at init.
            std.debug.assert(from.len <= to.capacity);
            to.items.len = from.len;
            @memcpy(to.items, from);
        } else {
            @field(dst, field.name) = @field(src, field.name);
        }
    }
    dst.credential = null;
    dst.known_count = 0;
    dst.known = undefined;
    for (dst.pending.items) |*entry| {
        entry.status = .lookup;
        entry.blocked_by = null;
    }
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const test_origin = "http://127.0.0.1:9";
const api_key = "vck_test_api_key";
const login_token = "fxlogin_test_token";

/// `gen_` and the sequence in Crockford base32, padded to 26 characters.
fn testId(n: u64) core.GenerationId {
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    var bytes: [core.GenerationId.length]u8 = undefined;
    @memcpy(bytes[0..4], "gen_");
    var value = n;
    var index: usize = bytes.len;
    while (index > 4) : (index -= 1) {
        bytes[index - 1] = alphabet[@intCast(value % 32)];
        value /= 32;
    }
    return core.GenerationId.parse(&bytes) catch unreachable;
}

fn foundBody(buffer: []u8, id: []const u8, cost: f64) []const u8 {
    return std.fmt.bufPrint(buffer,
        \\{{"data":{{"id":"{s}","total_cost":{d},"created_at":"2026-10-07T12:00:00.000Z","model":"openai/gpt-4.1-nano","native_tokens_prompt":10,"native_tokens_completion":5,"native_tokens_reasoning":0,"native_tokens_cached":0,"native_tokens_cache_creation":0,"billable_web_search_calls":0}}}}
    , .{ id, cost }) catch unreachable;
}

/// A scripted Gateway. Each answer is used once, in order; with none left
/// it answers 404. `hold` makes a fetch wait for its cancel flag.
const TestLookup = struct {
    mutex: Io.Mutex = .init,
    answers: [16]Answer = undefined,
    count: usize = 0,
    used: usize = 0,
    fetches: u32 = 0,
    /// The secret of the last request, to check what was sent.
    last_secret: [64]u8 = undefined,
    last_secret_len: ?usize = null,
    trust: bool = true,

    /// `slow_found` answers 200 after 50 ms, so the lookup is seen in flight.
    const Answer = union(enum) { status: u16, found: f64, slow_found: f64, hold, transport, canceled };

    fn add(t: *TestLookup, answer: Answer) void {
        t.answers[t.count] = answer;
        t.count += 1;
    }

    fn handle(t: *TestLookup) host.Lookup {
        return .{ .context = t, .vtable = &.{ .trusted = trusted, .fetch = fetch } };
    }

    fn trusted(context: *anyopaque, _: []const u8) bool {
        const t: *TestLookup = @ptrCast(@alignCast(context));
        return t.trust;
    }

    fn fetch(context: *anyopaque, request: *const host.Lookup.Request, body: []u8) host.Lookup.FetchError!host.Lookup.Response {
        const t: *TestLookup = @ptrCast(@alignCast(context));
        const answer = blk: {
            t.mutex.lockUncancelable(testing.io);
            defer t.mutex.unlock(testing.io);
            t.fetches += 1;
            t.last_secret_len = null;
            if (request.secret) |secret| {
                @memcpy(t.last_secret[0..secret.len], secret);
                t.last_secret_len = secret.len;
            }
            if (t.used == t.count) break :blk Answer{ .status = 404 };
            t.used += 1;
            break :blk t.answers[t.used - 1];
        };
        switch (answer) {
            .status => |status| return .{ .status = status, .body_len = 0 },
            .transport => return error.Transport,
            .canceled => return error.Canceled,
            .found => |cost| return .{ .status = 200, .body_len = foundBody(body, request.generation_id, cost).len },
            .slow_found => |cost| {
                testing.io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
                return .{ .status = 200, .body_len = foundBody(body, request.generation_id, cost).len };
            },
            .hold => {
                while (!request.cancel.load(.acquire)) {
                    testing.io.sleep(.fromMilliseconds(1), .awake) catch return error.Canceled;
                }
                return error.Canceled;
            },
        }
    }

    fn lastSecret(t: *TestLookup) ?[]const u8 {
        t.mutex.lockUncancelable(testing.io);
        defer t.mutex.unlock(testing.io);
        return if (t.last_secret_len) |len| t.last_secret[0..len] else null;
    }

    fn fetchCount(t: *TestLookup) u32 {
        t.mutex.lockUncancelable(testing.io);
        defer t.mutex.unlock(testing.io);
        return t.fetches;
    }
};

/// Records what each checkpoint held. Fails the first `fail` persists.
const TestSink = struct {
    fail: u32 = 0,
    count: u64 = 0,
    last_number: u64 = 0,
    pending: usize = 0,
    backlog: usize = 0,
    active: usize = 0,
    scrubbed: bool = true,

    fn handle(s: *TestSink) Sink {
        return .{ .context = s, .vtable = &.{ .persist = persist } };
    }

    fn persist(context: *anyopaque, checkpoint: *const Checkpoint) Sink.PersistError!void {
        const s: *TestSink = @ptrCast(@alignCast(context));
        if (s.fail > 0) {
            s.fail -= 1;
            return error.PersistFailed;
        }
        // Called under the worker's checkpoint lock: in order, one at a time.
        std.debug.assert(checkpoint.number > s.last_number);
        s.last_number = checkpoint.number;
        s.count += 1;
        const ledger = checkpoint.ledger;
        s.pending = ledger.pending.items.len;
        s.backlog = ledger.backlog.items.len;
        s.active = ledger.active.items.len;
        if (ledger.credential != null or ledger.known_count != 0) s.scrubbed = false;
        for (ledger.pending.items) |entry| if (entry.blocked_by != null) {
            s.scrubbed = false;
        };
    }
};

const TestPublisher = struct {
    busy: u32 = 0,
    published: u32 = 0,
    answer: Publisher.Answer = .appended,
    pending_records: u32 = 0,
    incidents: u32 = 0,

    fn handle(p: *TestPublisher) Publisher {
        return .{ .context = p, .vtable = &.{ .publish = publish } };
    }

    /// With pending records and incidents, as the profile ledger takes them.
    fn handleFull(p: *TestPublisher) Publisher {
        return .{ .context = p, .vtable = &.{ .publish = publish, .publish_pending = publishPending, .publish_incident = publishIncident } };
    }

    fn publish(context: *anyopaque, _: *const core.Fact) Publisher.PublishError!Publisher.Answer {
        const p: *TestPublisher = @ptrCast(@alignCast(context));
        if (p.busy > 0) {
            p.busy -= 1;
            return error.Busy;
        }
        p.published += 1;
        return p.answer;
    }

    fn publishPending(context: *anyopaque, _: *const Publisher.PendingRecord) Publisher.PublishError!void {
        const p: *TestPublisher = @ptrCast(@alignCast(context));
        p.pending_records += 1;
    }

    fn publishIncident(context: *anyopaque, _: core.Incident) Publisher.PublishError!void {
        const p: *TestPublisher = @ptrCast(@alignCast(context));
        p.incidents += 1;
    }
};

/// Records when the marker is written and cleared, against the sink's
/// checkpoint count at that moment.
const TestMarkers = struct {
    sink: *const TestSink,
    present: bool = false,
    /// Sink count at the first write, and at the last clear.
    first_write_at: ?u64 = null,
    last_clear_at: ?u64 = null,
    writes: u32 = 0,
    clears: u32 = 0,
    at_ms: i64 = 0,

    fn handle(m: *TestMarkers) Markers {
        return .{ .context = m, .vtable = &.{ .prepare = prepare, .clear = clear } };
    }

    fn prepare(context: *anyopaque, input: Markers.Input) Markers.Error!i64 {
        const m: *TestMarkers = @ptrCast(@alignCast(context));
        if (input.next_owes and !m.present) {
            m.present = true;
            m.writes += 1;
            if (m.first_write_at == null) m.first_write_at = m.sink.count;
        }
        m.at_ms = @max(input.now_ms, input.saved_at_ms + 1);
        return m.at_ms;
    }

    fn clear(context: *anyopaque) Markers.Error!void {
        const m: *TestMarkers = @ptrCast(@alignCast(context));
        m.present = false;
        m.clears += 1;
        m.last_clear_at = m.sink.count;
    }
};

const Rig = struct {
    worker: Worker = undefined,
    lookup: TestLookup = .{},
    sink: TestSink = .{},
    publisher: TestPublisher = .{},
    rows: [4]core.ModelRow = undefined,

    fn start(r: *Rig, schedule: Schedule) !void {
        try r.worker.init(testing.allocator, testing.io, .{
            .lookup = r.lookup.handle(),
            .sink = r.sink.handle(),
            .publisher = r.publisher.handle(),
            .schedule = schedule,
        });
    }

    fn finish(r: *Rig) void {
        r.worker.close() catch {};
        r.worker.deinit();
    }

    fn view(r: *Rig) core.View {
        return r.worker.view(&r.rows);
    }

    fn begin(r: *Rig) !core.Sequence {
        return (try r.worker.report(.{ .begin = .gateway })).call;
    }

    fn finishLookup(r: *Rig, sequence: core.Sequence) !void {
        _ = try r.worker.report(.{ .finish_lookup = .{ .sequence = sequence, .request = .{
            .id = testId(sequence),
            .origin = test_origin,
            .credential_source = .ai_gateway_api_key,
            .observed_at_ms = 1_000,
        } } });
    }

    /// Polls `done` until it holds, for at most `ms`.
    fn waitFor(r: *Rig, ms: u32, done: *const fn (*Rig) bool) !void {
        var waited: u32 = 0;
        while (!done(r)) : (waited += 1) {
            if (waited >= ms) return error.TestTimedOut;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn settled(r: *Rig) bool {
        const v = r.view();
        return v.pending == 0 and v.backlog == 0;
    }

    fn blocked(r: *Rig) bool {
        return r.view().unpriced.sign_in_cannot_look_up > 0;
    }

    fn idle(r: *Rig) bool {
        return !r.worker.stats().running;
    }
};

const fast: Schedule = .{ .first_ms = 2, .max_ms = 8 };

test "the default schedule covers the 20 s ingestion delay without spinning" {
    const schedule: Schedule = .{};
    var at: u64 = 0;
    var requests: u32 = 1;
    var retry: u32 = 1;
    while (at < 20_000) : (retry += 1) {
        at += schedule.delayMs(retry);
        requests += 1;
    }
    // Requests at 0, 1, 2, 4, 6, 10, 14, and 22 s: the 8th is the first
    // after 20 s.
    try testing.expectEqual(@as(u64, 22_000), at);
    try testing.expectEqual(@as(u32, 8), requests);
    // Never faster than the first delay, never slower than the cap.
    try testing.expectEqual(@as(u32, 1_000), schedule.delayMs(1));
    try testing.expectEqual(@as(u32, 1_000), schedule.delayMs(2));
    try testing.expectEqual(@as(u32, 2_000), schedule.delayMs(3));
    try testing.expectEqual(@as(u32, 60_000), schedule.delayMs(13));
    try testing.expectEqual(@as(u32, 60_000), schedule.delayMs(std.math.maxInt(u32)));
}

test "a schedule that could spin is refused" {
    var w: Worker = undefined;
    var lookup: TestLookup = .{};
    var sink: TestSink = .{};
    var publisher: TestPublisher = .{};
    try testing.expectError(error.InvalidSchedule, w.init(testing.allocator, testing.io, .{
        .lookup = lookup.handle(),
        .sink = sink.handle(),
        .publisher = publisher.handle(),
        .schedule = .{ .first_ms = 0 },
    }));
}

test "nothing starts until the core has lookup or publication work" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    const call = try r.begin();
    try testing.expectEqual(@as(u32, 0), r.worker.stats().spawns);
    try testing.expectEqual(@as(u64, 1), r.sink.count);
    _ = try r.worker.report(.{ .finish_unbilled = call });
    try testing.expectEqual(@as(u32, 0), r.worker.stats().spawns);
}

test "awaitLookups returns once a due lookup is answered" {
    var r: Rig = .{};
    try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = api_key });
    // Slow enough that the lookup is in flight, no longer queued, while
    // awaitLookups checks.
    r.lookup.add(.{ .slow_found = 0.5 });
    const call = try r.begin();
    try r.finishLookup(call);
    r.worker.awaitLookups(2_000);
    try testing.expect(r.view().pending == 0);
    try testing.expectEqual(@as(u32, 1), r.worker.stats().lookups);
    try testing.expectEqual(@as(f64, 0.5), r.view().totals.total_cost);
}

test "awaitLookups stops at its budget and leaves backed-off entries waiting" {
    var r: Rig = .{};
    try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = api_key });
    r.lookup.add(.{ .status = 404 });
    const call = try r.begin();
    try r.finishLookup(call);
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    // The 404 backs off for a minute: nothing is due, so it returns at once.
    r.worker.awaitLookups(5_000);
    const waited = started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds();
    try testing.expect(waited < 2_000);
    try testing.expect(r.view().pending == 1);
    try testing.expectEqual(@as(u32, 1), r.worker.stats().lookups);

    // A lookup that never answers is given only the budget.
    var held: Rig = .{};
    try held.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    defer held.finish();
    try held.worker.setCredential(.{ .bearer = api_key });
    held.lookup.add(.hold);
    const held_call = try held.begin();
    try held.finishLookup(held_call);
    const held_started = Io.Clock.Timestamp.now(testing.io, .awake);
    held.worker.awaitLookups(50);
    const held_waited = held_started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds();
    // The deadline counts from the current whole millisecond, so the wait
    // can measure one millisecond short of the budget.
    try testing.expect(held_waited >= 49 and held_waited < 2_000);
}

test "a lookup that 404s then 200s settles, and the task exits when idle" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = api_key });
    r.lookup.add(.{ .status = 404 });
    r.lookup.add(.{ .status = 404 });
    r.lookup.add(.{ .found = 0.5 });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.settled);
    try r.waitFor(2_000, Rig.idle);
    const s = r.worker.stats();
    try testing.expectEqual(@as(u32, 1), s.spawns);
    try testing.expectEqual(@as(u32, 1), s.idle_exits);
    try testing.expectEqual(@as(u32, 1), s.peak_tasks);
    try testing.expectEqual(@as(u32, 3), s.lookups);
    try testing.expect(s.waits >= 2);
    try testing.expectEqual(@as(f64, 0.5), r.view().totals.total_cost);
    try testing.expectEqual(@as(u32, 1), r.publisher.published);
    try testing.expectEqualStrings(api_key, r.lookup.lastSecret().?);
    try testing.expect(r.sink.scrubbed);
}

test "401 blocks only that credential; a different one retries and settles" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = login_token });
    r.lookup.add(.{ .status = 401 });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.blocked);
    try r.waitFor(2_000, Rig.idle);
    // The same credential again changes nothing and starts nothing.
    try r.worker.setCredential(.{ .bearer = login_token });
    try testing.expectEqual(@as(u32, 1), r.worker.stats().spawns);
    try testing.expectEqual(@as(u32, 1), r.lookup.fetchCount());

    r.lookup.add(.{ .found = 0.25 });
    try r.worker.setCredential(.{ .bearer = api_key });
    try r.waitFor(2_000, Rig.settled);
    try testing.expectEqual(@as(u32, 2), r.worker.stats().spawns);
    try testing.expectEqual(@as(f64, 0.25), r.view().totals.total_cost);
    try testing.expectEqualStrings(api_key, r.lookup.lastSecret().?);
}

test "429, 5xx, and transport errors retry; another 4xx rejects with an incident" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = api_key });
    r.lookup.add(.{ .status = 429 });
    r.lookup.add(.transport);
    r.lookup.add(.{ .status = 503 });
    r.lookup.add(.{ .status = 400 });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.settled);
    const v = r.view();
    try testing.expectEqual(@as(u64, 1), v.unpriced.no_receipt);
    try testing.expectEqual(core.Availability.incomplete, v.availability);
    try testing.expectEqual(@as(u32, 4), r.lookup.fetchCount());
}

test "a cancel the worker didn't ask for backs off like a transport failure" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = api_key });
    r.lookup.add(.canceled);
    r.lookup.add(.canceled);
    r.lookup.add(.{ .found = 0.5 });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.settled);
    const s = r.worker.stats();
    try testing.expectEqual(@as(u32, 0), s.canceled);
    try testing.expectEqual(@as(u32, 3), s.lookups);
    try testing.expect(s.waits >= 2);
}

test "an untrusted origin is rejected without a request" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    r.lookup.trust = false;
    try r.worker.setCredential(.{ .bearer = api_key });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.settled);
    try testing.expectEqual(@as(u32, 0), r.lookup.fetchCount());
    try testing.expectEqual(@as(u32, 1), r.worker.stats().untrusted);
    try testing.expectEqual(@as(u64, 1), r.view().unpriced.no_receipt);
}

test "signing out stops lookups; signing in resumes them" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = login_token });
    r.lookup.add(.{ .status = 401 });
    const call = try r.begin();
    try r.finishLookup(call);
    try r.waitFor(2_000, Rig.blocked);
    try r.worker.setCredential(.signed_out);
    try testing.expectEqual(@as(u32, 1), r.view().unpriced.lookup_pending);
    try r.waitFor(2_000, Rig.idle);
    try testing.expectEqual(@as(u32, 1), r.lookup.fetchCount());
    try testing.expectEqual(@as(u32, 0), r.worker.stats().scheduled_lookups);
    r.lookup.add(.{ .found = 1 });
    try r.worker.setCredential(.host_managed);
    try r.waitFor(2_000, Rig.settled);
    // Host-managed auth sends no secret.
    try testing.expectEqual(@as(?[]const u8, null), r.lookup.lastSecret());
}

test "a new credential cancels the lookup in flight and looks up again with it" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = login_token });
    r.lookup.add(.hold);
    r.lookup.add(.{ .found = 2 });
    const call = try r.begin();
    try r.finishLookup(call);
    const InFlight = struct {
        fn started(rig: *Rig) bool {
            return rig.lookup.fetchCount() == 1;
        }
    };
    try r.waitFor(2_000, InFlight.started);
    try r.worker.setCredential(.{ .bearer = api_key });
    try r.waitFor(2_000, Rig.settled);
    try testing.expectEqual(@as(u32, 1), r.worker.stats().canceled);
    try testing.expectEqual(@as(f64, 2), r.view().totals.total_cost);
}

test "close during a lookup joins quickly and leaves the entry in the last checkpoint" {
    var r: Rig = .{};
    try r.start(fast);
    try r.worker.setCredential(.{ .bearer = api_key });
    r.lookup.add(.hold);
    const call = try r.begin();
    try r.finishLookup(call);
    const InFlight = struct {
        fn started(rig: *Rig) bool {
            return rig.lookup.fetchCount() == 1;
        }
    };
    try r.waitFor(2_000, InFlight.started);
    const before = Io.Clock.Timestamp.now(testing.io, .awake);
    try r.worker.close();
    const took = before.untilNow(testing.io).raw.toMilliseconds();
    try testing.expect(took < 250);
    try testing.expectEqual(@as(usize, 1), r.sink.pending);
    try testing.expectError(error.Closed, r.worker.report(.{ .begin = .gateway }));
    try testing.expectError(error.Closed, r.worker.setCredential(.signed_out));
    try r.worker.close();
    try testing.expect(std.mem.allEqual(u8, &r.worker.held.secret, 0));
    r.worker.deinit();
}

test "close during a backoff wait doesn't wait it out" {
    var r: Rig = .{};
    try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    try r.worker.setCredential(.{ .bearer = api_key });
    const call = try r.begin();
    try r.finishLookup(call);
    const Waiting = struct {
        fn started(rig: *Rig) bool {
            return rig.worker.stats().waits > 0;
        }
    };
    try r.waitFor(2_000, Waiting.started);
    const before = Io.Clock.Timestamp.now(testing.io, .awake);
    try r.worker.close();
    try testing.expect(before.untilNow(testing.io).raw.toMilliseconds() < 250);
    r.worker.deinit();
}

test "a failed checkpoint fails the report, is retried, and close writes what is owed" {
    var r: Rig = .{};
    try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    const call = try r.begin();
    try testing.expectEqual(@as(u64, 1), r.sink.count);
    r.sink.fail = 1;
    try testing.expectError(error.CheckpointFailed, r.worker.report(.{ .finish_unbilled = call }));
    try testing.expectEqual(@as(u64, 1), r.sink.count);
    try testing.expect(r.worker.stats().running);
    try r.worker.close();
    try testing.expectEqual(@as(u64, 2), r.sink.count);
    try testing.expectEqual(@as(usize, 0), r.sink.active);
    r.worker.deinit();
}

test "a begin whose checkpoint fails ends unbilled, so nothing stays in flight" {
    var r: Rig = .{};
    try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
    r.sink.fail = 1;
    try testing.expectError(error.CheckpointFailed, r.worker.report(.{ .begin = .gateway }));
    try testing.expectEqual(@as(u64, 1), r.sink.count);
    try testing.expectEqual(@as(usize, 0), r.sink.active);
    try r.worker.close();
    r.worker.deinit();
}

test "a busy profile ledger is retried until the fact publishes" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    r.publisher.busy = 2;
    const call = try r.begin();
    _ = try r.worker.report(.{ .finish_exact = .{ .sequence = call, .fact = .{
        .id = testId(call),
        .created_at_ms = 1,
        .model = "openai/gpt-4.1-nano",
        .total_cost = 0.125,
    } } });
    try r.waitFor(2_000, Rig.settled);
    try testing.expectEqual(@as(u32, 1), r.publisher.published);
    try testing.expectEqual(@as(u32, 2), r.worker.stats().publish_failures);
    try testing.expectEqual(@as(f64, 0.125), r.view().totals.total_cost);
}

test "freeze copies every list and scrubs credentials" {
    var src = try core.Ledger.init(testing.allocator, .{}, .fresh);
    defer src.deinit(testing.allocator);
    var dst = try core.Ledger.init(testing.allocator, .{}, .fresh);
    defer dst.deinit(testing.allocator);
    var out: core.Output = .{};
    try src.step(.{ .set_credential = core.credentialDigest(login_token) }, &out, null);
    try src.step(.{ .begin = .gateway }, &out, null);
    try src.step(.{ .begin = .gateway }, &out, null);
    try src.step(.{ .finish_lookup = .{ .sequence = 1, .request = .{ .id = testId(1), .origin = test_origin, .credential_source = .fx_login, .observed_at_ms = 1 } } }, &out, null);
    try src.step(.{ .lookup_unauthorized = 1 }, &out, null);
    freeze(&dst, &src);
    try testing.expectEqual(src.next_sequence, dst.next_sequence);
    try testing.expectEqual(@as(usize, 1), dst.active.items.len);
    try testing.expectEqual(@as(usize, 1), dst.pending.items.len);
    try testing.expect(dst.active.items.ptr != src.active.items.ptr);
    try testing.expectEqual(@as(?@TypeOf(dst.credential.?), null), dst.credential);
    try testing.expectEqual(@as(usize, 0), dst.known_count);
    try testing.expectEqual(core.LookupStatus.lookup, dst.pending.items[0].status);
    try testing.expectEqual(@as(?core.Digest, null), dst.pending.items[0].blocked_by);
    // The source keeps its runtime state.
    try testing.expectEqual(core.LookupStatus.blocked, src.pending.items[0].status);
}

test "an answer sent with a credential that has since changed is dropped" {
    var r: Rig = .{};
    try r.start(fast);
    defer r.finish();
    try r.worker.setCredential(.{ .bearer = login_token });
    {
        r.worker.state.lockUncancelable(testing.io);
        defer r.worker.state.unlock(testing.io);
        r.worker.in_flight = .{ .sequence = 1, .digest = core.credentialDigest(api_key) };
    }
    r.worker.answer(.{ .lookup_unauthorized = 1 }, .answer);
    try testing.expectEqual(@as(u32, 1), r.worker.stats().stale_answers);
}

fn exactFact(sequence: core.Sequence, cost: f64) core.Fact {
    return .{ .id = testId(sequence + 100), .created_at_ms = 5, .model = "model/x", .total_cost = cost, .input_tokens = 3, .output_tokens = 2 };
}

fn idleAndSettled(r: *Rig) bool {
    return Rig.settled(r) and Rig.idle(r);
}

test "the marker is durable before a checkpoint that owes and cleared after one that owes nothing" {
    var r: Rig = .{};
    var markers: TestMarkers = .{ .sink = &r.sink };
    var trace_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer trace_out.deinit();
    var tracer: trace.Writer = .init(&trace_out.writer);
    try r.worker.init(testing.allocator, testing.io, .{
        .lookup = r.lookup.handle(),
        .sink = r.sink.handle(),
        .publisher = r.publisher.handle(),
        .markers = markers.handle(),
        .schedule = fast,
        .tracer = &tracer,
    });
    defer r.finish();
    const call = try r.begin();
    // The call in flight owes the ledger, so the marker came first.
    try testing.expectEqual(@as(?u64, 0), markers.first_write_at);
    _ = try r.worker.report(.{ .finish_exact = .{ .sequence = call, .fact = exactFact(call, 0.25) } });
    try r.waitFor(2_000, idleAndSettled);
    try testing.expectEqual(@as(u32, 1), markers.writes);
    try testing.expectEqual(@as(u32, 1), markers.clears);
    // Cleared only after the checkpoint that owes nothing was durable.
    try testing.expectEqual(@as(?u64, r.sink.count), markers.last_clear_at);
    try testing.expect(!r.worker.publication.marker);
    try testing.expectEqual(@as(u32, 0), r.worker.stats().trace_errors);
    try testing.expectEqual(@as(f64, 0.25), r.view().totals.total_cost);
    const written = trace_out.written();
    for ([_][]const u8{ "write_marker", "stage", "append", "settle", "clear_marker" }) |event| {
        var needle: [32]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&needle, "\"event\":\"{s}\"", .{event});
        try testing.expect(std.mem.indexOf(u8, written, quoted) != null);
    }
}

test "a conflict answer is never retried, and its incident reaches the profile" {
    var r: Rig = .{};
    r.publisher.answer = .conflict;
    try r.worker.init(testing.allocator, testing.io, .{
        .lookup = r.lookup.handle(),
        .sink = r.sink.handle(),
        .publisher = r.publisher.handleFull(),
        .schedule = fast,
    });
    defer r.finish();
    const call = try r.begin();
    _ = try r.worker.report(.{ .finish_exact = .{ .sequence = call, .fact = exactFact(call, 1) } });
    try r.waitFor(2_000, idleAndSettled);
    const s = r.worker.stats();
    try testing.expectEqual(@as(u32, 1), s.publishes);
    try testing.expectEqual(@as(u32, 1), s.conflicts);
    try testing.expectEqual(@as(u32, 1), s.incidents_published);
    try testing.expectEqual(@as(u32, 1), r.publisher.published);
    try testing.expectEqual(@as(u32, 1), r.publisher.incidents);
    const v = r.view();
    try testing.expectEqual(@as(f64, 0), v.totals.total_cost);
    try testing.expectEqual(core.Availability.incomplete, v.availability);
    try testing.expectEqual(@as(u64, 1), v.unpriced.no_receipt);
}

test "only real lookups publish a pending record" {
    var r: Rig = .{};
    try r.worker.init(testing.allocator, testing.io, .{
        .lookup = r.lookup.handle(),
        .sink = r.sink.handle(),
        .publisher = r.publisher.handleFull(),
        .schedule = fast,
    });
    defer r.finish();
    const exact = try r.begin();
    const waiting = try r.begin();
    _ = try r.worker.report(.{ .finish_exact = .{ .sequence = exact, .fact = exactFact(exact, 1) } });
    try r.finishLookup(waiting);
    try r.waitFor(2_000, struct {
        fn done(rig: *Rig) bool {
            return rig.worker.stats().pending_records == 1 and rig.publisher.published == 1;
        }
    }.done);
    try r.waitFor(2_000, Rig.idle);
    try testing.expectEqual(@as(u32, 1), r.publisher.pending_records);
}

test "a restored backlog publishes once start runs, from a traced restart" {
    var r: Rig = .{};
    var markers: TestMarkers = .{ .sink = &r.sink, .present = true };
    var trace_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer trace_out.deinit();
    var tracer: trace.Writer = .init(&trace_out.writer);
    const staged = [_]core.Restored.StagedFact{.{ .sequence = 2, .fact = exactFact(2, 0.5) }};
    try r.worker.init(testing.allocator, testing.io, .{
        .lookup = r.lookup.handle(),
        .sink = r.sink.handle(),
        .publisher = r.publisher.handle(),
        .markers = markers.handle(),
        .restore = .{ .saved = .{
            .availability = .complete,
            .next_sequence = 3,
            .settled_through = 2,
            .totals = .{},
            .backlog = &staged,
        }, .saved_at_ms = 10, .marker = true },
        .schedule = fast,
        .tracer = &tracer,
    });
    defer r.finish();
    // Nothing runs before start.
    try testing.expectEqual(@as(u32, 0), r.worker.stats().spawns);
    r.worker.start();
    try r.waitFor(2_000, idleAndSettled);
    try testing.expectEqual(@as(u32, 1), r.publisher.published);
    try testing.expectEqual(@as(f64, 0.5), r.view().totals.total_cost);
    try testing.expect(!markers.present);
    // The checkpoint after a restart is strictly later than the saved one.
    try testing.expect(markers.at_ms > 10);
    try testing.expect(std.mem.indexOf(u8, trace_out.written(), "\"event\":\"restart\"") != null);
    try testing.expectEqual(@as(u32, 0), r.worker.stats().trace_errors);
}

test "close publishes what is still owed once, and a busy ledger leaves it staged for the next run" {
    {
        var r: Rig = .{};
        try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
        const call = try r.begin();
        _ = try r.worker.report(.{ .finish_exact = .{ .sequence = call, .fact = exactFact(call, 0.75) } });
        try r.worker.close();
        // Published by the task or by close, but exactly once.
        try testing.expectEqual(@as(u32, 1), r.publisher.published);
        try testing.expectEqual(@as(usize, 0), r.sink.backlog);
        r.worker.deinit();
    }
    {
        var r: Rig = .{};
        r.publisher.busy = std.math.maxInt(u32);
        try r.start(.{ .first_ms = 60_000, .max_ms = 60_000 });
        const call = try r.begin();
        _ = try r.worker.report(.{ .finish_exact = .{ .sequence = call, .fact = exactFact(call, 0.75) } });
        const busy_before_close = r.publisher.busy;
        try r.worker.close();
        // At most one attempt at close, and the fact is in the last checkpoint.
        try testing.expect(busy_before_close - r.publisher.busy <= 1);
        try testing.expectEqual(@as(u32, 0), r.publisher.published);
        try testing.expectEqual(@as(usize, 1), r.sink.backlog);
        r.worker.deinit();
    }
}

test "a lookup that resolves before its pending record publishes leaves nothing to publish" {
    var r: Rig = .{};
    try r.worker.init(testing.allocator, testing.io, .{
        .lookup = r.lookup.handle(),
        .sink = r.sink.handle(),
        .publisher = r.publisher.handle(),
        .schedule = fast,
    });
    defer r.finish();
    // Step the core directly so the task never runs: the record is queued,
    // then the entry is rejected before the record goes out.
    const w = &r.worker;
    var out: core.Output = .{};
    try w.ledger.step(.{ .set_credential = core.credentialDigest(api_key) }, &out, null);
    try w.ledger.step(.{ .begin = .gateway }, &out, null);
    _ = w.afterStepLocked(&out, .report);
    try w.ledger.step(.{ .finish_lookup = .{ .sequence = 1, .request = .{ .id = testId(1), .origin = test_origin, .credential_source = .ai_gateway_api_key, .observed_at_ms = 1 } } }, &out, null);
    _ = w.afterStepLocked(&out, .report);
    try testing.expectEqual(@as(usize, 1), w.pending_record_count);
    try w.ledger.step(.{ .lookup_rejected = 1 }, &out, null);
    _ = w.afterStepLocked(&out, .answer);
    w.dirty = false;
    // The stale record is dropped; with no incident publisher there is nothing to do.
    try testing.expectEqual(Next.exit, w.next());
    try testing.expectEqual(@as(usize, 0), w.pending_record_count);
}
