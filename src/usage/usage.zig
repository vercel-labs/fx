//! The usage module's front door.
//!
//! - `Profile`: one per process. Opens nothing until first use, and a
//!   `read_only` profile never creates `~/.fx`. Rolling views, and the
//!   profile ledger every session publishes to.
//! - `Ledger`: one per session (TUI, `fx ask`, each ACP session). Restores the
//!   saved snapshot, records calls, persists checkpoints through the host's
//!   `SessionSink`, keeps the recovery marker, and publishes to the profile.
//! - `Call`: one model call, from `begin` to `finish`.
//! - `snapshot`: the session snapshot formats the session store keeps.
//! - `render`: the surfaces' text and JSON, byte-identical to today.
//!
//! One sealed module: files under src/usage/ import only `std` and each
//! other, and fx reaches them only through this file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const host = @import("host.zig");
pub const report = @import("report.zig");
pub const render = @import("render.zig");
pub const trace = @import("trace.zig");

const checkpoint = @import("checkpoint.zig");
const core = @import("core/ledger.zig");
const durable = @import("io/durable.zig");
const markers = @import("io/markers.zig");
const profile_store = @import("io/profile.zig");
const receipt = @import("receipt.zig");
pub const snapshot = @import("codec/snapshot.zig");
/// `snapshot` under a name `Ledger.snapshot` doesn't shadow.
const snapshot_codec = snapshot;
const worker = @import("io/worker.zig");

pub const Provider = core.Provider;
pub const CredentialSource = core.CredentialSource;
pub const Scope = report.Scope;
pub const View = report.View;
pub const TurnUsage = report.TurnUsage;
pub const Snapshot = snapshot.Snapshot;
pub const MarkerKind = markers.Kind;
pub const Limits = core.Limits;
pub const Schedule = worker.Schedule;
pub const Stats = worker.Stats;
pub const WallStart = worker.WallStart;
pub const Start = core.Start;
pub const Probe = durable.Probe;

/// The module's internals, for development tools outside fx only. fx uses
/// the declarations above; nothing it ships may name `dev`.
pub const dev = struct {
    pub const checkpoint = @import("checkpoint.zig");
    pub const receipt = @import("receipt.zig");
    pub const core = struct {
        pub const ledger = @import("core/ledger.zig");
        pub const publish = @import("core/publish.zig");
    };
    pub const codec = struct {
        pub const record = @import("codec/record.zig");
        pub const snapshot = @import("codec/snapshot.zig");
    };
    pub const io = struct {
        pub const durable = @import("io/durable.zig");
        pub const markers = @import("io/markers.zig");
        pub const profile = @import("io/profile.zig");
        pub const worker = @import("io/worker.zig");
    };
};

/// The production Gateway origin.
pub const default_origin = "https://ai-gateway.vercel.sh";

// ---------------------------------------------------------------------------
// Profile

pub const Profile = struct {
    gpa: Allocator,
    io: Io,
    home: Io.Dir,
    mode: Mode,
    recovery_source: ?host.RecoverySource,
    probe: durable.Probe,
    store_lock: Io.Mutex = .init,
    store: profile_store.Store,

    pub const Mode = profile_store.Mode;

    pub const Options = struct {
        /// The directory that holds `.fx` (the user's HOME). Borrowed; open
        /// it with `.iterate = true`.
        home: Io.Dir,
        mode: Mode,
        /// Reads marked sessions for rolling views. Without it every marker
        /// is an orphan: an incident at its protected time.
        recovery: ?host.RecoverySource = null,
        /// Crash points, for tests and the dev lab. Empty in production.
        probe: durable.Probe = .{},
    };

    /// Does no I/O. The profile must not move while a ledger is open.
    pub fn init(gpa: Allocator, io: Io, options: Options) Profile {
        return .{
            .gpa = gpa,
            .io = io,
            .home = options.home,
            .mode = options.mode,
            .recovery_source = options.recovery,
            .probe = options.probe,
            .store = .init(gpa, io, .{ .home = options.home, .mode = options.mode, .probe = options.probe }),
        };
    }

    /// Every ledger must be closed first.
    pub fn deinit(p: *Profile) void {
        p.store.deinit();
        p.* = undefined;
    }

    /// A rolling view (24h, 7d, 30d) at `now_ms`: the profile ledger plus
    /// what marked sessions still owe it. The caller owns the result.
    pub fn view(p: *Profile, gpa: Allocator, scope: Scope, now_ms: i64) !View {
        if (scope == .session) return error.SessionScope;
        var out: [1]View = undefined;
        try p.rolling(gpa, now_ms, &.{scope}, &out);
        return out[0];
    }

    /// The three rolling views, in `Scope.rolling` order, from one read of
    /// the profile ledger. The caller owns all three.
    pub fn views(p: *Profile, gpa: Allocator, now_ms: i64) ![Scope.rolling.len]View {
        var out: [Scope.rolling.len]View = undefined;
        try p.rolling(gpa, now_ms, &Scope.rolling, &out);
        return out;
    }

    /// Builds `out[i]` for `scopes[i]` from one read. On error `out` holds
    /// nothing owned.
    fn rolling(p: *Profile, gpa: Allocator, now_ms: i64, scopes: []const Scope, out: []View) !void {
        var stored = blk: {
            p.store_lock.lockUncancelable(p.io);
            defer p.store_lock.unlock(p.io);
            break :blk try p.store.read();
        };
        defer stored.release();
        var collector: report.RecoveryCollector = .{};
        defer collector.deinit(gpa);
        try p.collectRecovery(gpa, &collector);
        const contents = stored.ledger();
        const ledger: report.LedgerContents = .{
            .coverage_started_at_ms = contents.coverage_started_at_ms,
            .facts = contents.facts,
            .pending = contents.pending,
            .incidents = contents.incidents,
        };
        var built: usize = 0;
        errdefer for (out[0..built]) |*view_| view_.deinit(gpa);
        for (scopes, out) |scope, *dst| {
            dst.* = try report.rollingView(gpa, ledger, collector.recovery(), scope, now_ms, .{});
            built += 1;
        }
    }

    /// Process exit: stop waiting on `usage.lock` held by another process.
    /// What is unpublished stays in the session checkpoints and under their
    /// markers. Safe from any thread.
    pub fn abandon(p: *Profile) void {
        p.store.abandon();
    }

    /// What every marked session still owes the profile ledger. Malformed
    /// and orphan markers are incidents; a session that can't be
    /// read or proven current is unknown, as today.
    fn collectRecovery(p: *Profile, gpa: Allocator, collector: *report.RecoveryCollector) Allocator.Error!void {
        if (p.recovery_source) |source| if (!source.available()) {
            collector.markUnknown();
            return;
        };
        for ([_]markers.Kind{ .v1, .v2 }) |kind| {
            var registry = markers.list(gpa, p.io, p.home, kind) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    collector.markUnknown();
                    continue;
                },
            };
            defer registry.deinit(gpa);
            if (registry.omitted > 0) collector.markUnknown();
            for (registry.entries) |entry| switch (entry.state) {
                .malformed => {
                    const modified_ns = entry.modified_at_ns orelse {
                        collector.markUnknown();
                        continue;
                    };
                    try collector.addIncident(gpa, .{ .occurred_at_ms = msFromNs(modified_ns), .completeness = .incomplete });
                },
                .marker => |protected_ms| try p.recoverSession(gpa, collector, kind, entry, protected_ms),
            };
        }
    }

    fn recoverSession(p: *Profile, gpa: Allocator, collector: *report.RecoveryCollector, kind: markers.Kind, entry: markers.Entry, protected_ms: i64) Allocator.Error!void {
        const orphan: report.Incident = .{ .occurred_at_ms = @max(protected_ms, 0), .completeness = .incomplete };
        const source = p.recovery_source orelse return collector.addIncident(gpa, orphan);
        const saved = source.load(switch (kind) {
            .v1 => .v1,
            .v2 => .v2,
        }, entry.name) orelse return collector.addIncident(gpa, orphan);
        switch (kind) {
            .v1 => {
                var sidecar = snapshot.parseSidecar(gpa, saved.bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return collector.markUnknown(),
                };
                defer sidecar.deinit(gpa);
                const marker_ns = entry.modified_at_ns orelse return collector.markUnknown();
                if (!std.mem.eql(u8, sidecar.session_id, entry.name)) return collector.markUnknown();
                const newer = report.v1CheckpointIsNewer(&sidecar.snapshot, saved.updated_at_ms, saved.modified_ns, marker_ns, protected_ms);
                try collector.addSession(gpa, &sidecar.snapshot, saved.updated_at_ms, newer);
            },
            .v2 => {
                var value = snapshot.parseV2Value(gpa, saved.bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return collector.markUnknown(),
                };
                defer value.deinit(gpa);
                const newer = report.v2CheckpointIsNewer(&value.snapshot, value.at_ms, protected_ms);
                try collector.addSession(gpa, &value.snapshot, value.at_ms, newer);
            },
        }
    }

    /// Opens one session's ledger and starts what its saved snapshot owes.
    pub fn openLedger(p: *Profile, options: Ledger.Options) !*Ledger {
        if (p.mode == .read_only) return error.ReadOnlyProfile;
        if (!markers.validSessionId(options.marker, options.session_id)) return error.InvalidSessionId;
        if (options.origin.len == 0 or options.origin.len > core.max_origin_bytes) return error.InvalidOrigin;
        const l = try p.gpa.create(Ledger);
        errdefer p.gpa.destroy(l);
        const session_id = try p.gpa.dupe(u8, options.session_id);
        errdefer p.gpa.free(session_id);
        const origin = try p.gpa.dupe(u8, options.origin);
        errdefer p.gpa.free(origin);
        var limits = options.limits;
        limits.bridge_origin_bytes = @intCast(origin.len);
        l.* = .{
            .gpa = p.gpa,
            .io = p.io,
            .profile = p,
            .sink = options.sink,
            .kind = options.marker,
            .session_id = session_id,
            .origin = origin,
            .limits = limits,
            .can_look_up = options.lookup != null,
            .worker = undefined,
        };

        // Unreadable counts as present: the publication machine then clears
        // it rather than trusting it gone.
        const marker = if (markers.read(p.io, p.home, options.marker, session_id)) |found| found != null else |_| true;
        try l.initWorker(options.saved, marker, .{
            .limits = limits,
            .start = options.start,
            .lookup = options.lookup orelse l.noLookup(),
            .sink = .{ .context = l, .vtable = &Ledger.sink_vtable },
            .publisher = .{ .context = l, .vtable = &Ledger.publisher_vtable },
            .markers = .{ .context = l, .vtable = &Ledger.markers_vtable },
            .existing_marker = marker,
            .trace_instance = options.trace_instance,
            .schedule = options.schedule,
            .tracer = options.tracer,
            .wall_start = options.wall_start,
        });
        l.worker.start();
        return l;
    }

    fn append(p: *Profile, event: profile_store.Event) worker.Publisher.PublishError!profile_store.Outcome {
        p.store_lock.lockUncancelable(p.io);
        defer p.store_lock.unlock(p.io);
        return p.store.append(event, wallMs(p.io)) catch |err| switch (err) {
            error.UsageLockBusy => error.Busy,
            else => error.Failed,
        };
    }
};

fn msFromNs(ns: i128) i64 {
    return @intCast(std.math.clamp(@divFloor(ns, std.time.ns_per_ms), 0, std.math.maxInt(i64)));
}

fn wallMs(io: Io) i64 {
    return Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

// ---------------------------------------------------------------------------
// Saved snapshots

/// A session's saved usage, as the session store holds it.
pub const Saved = union(enum) {
    /// v1 sidecar bytes (`sessions/<id>/usage-v2.json`) and the session's
    /// update time.
    sidecar: struct { bytes: []const u8, updated_at_ms: i64 },
    /// A sessions-v2 `set usage` value (it carries its own `at_ms`).
    v2_value: []const u8,
    /// A bare snapshot, rich or the 18-key shape (v3 events, state blobs).
    snapshot: struct { bytes: []const u8, at_ms: i64 },
    /// A snapshot the session store already parsed, and its time. Borrowed
    /// for `openLedger`.
    parsed: struct { snapshot: *const Snapshot, at_ms: i64 },

    const Parsed = struct {
        snapshot: Snapshot,
        at_ms: i64,

        fn deinit(parsed: *Parsed, gpa: Allocator) void {
            parsed.snapshot.deinit(gpa);
        }
    };

    fn parse(saved: Saved, gpa: Allocator) !Parsed {
        switch (saved) {
            .sidecar => |value| {
                const sidecar = try snapshot.parseSidecar(gpa, value.bytes);
                gpa.free(sidecar.session_id);
                return .{ .snapshot = sidecar.snapshot, .at_ms = value.updated_at_ms };
            },
            .v2_value => |bytes| {
                const value = try snapshot.parseV2Value(gpa, bytes);
                return .{ .snapshot = value.snapshot, .at_ms = value.at_ms };
            },
            .snapshot => |value| {
                var json = std.json.parseFromSlice(std.json.Value, gpa, value.bytes, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidUsageSnapshot,
                };
                defer json.deinit();
                return .{ .snapshot = try snapshot.parseValue(gpa, json.value), .at_ms = value.at_ms };
            },
            .parsed => |value| {
                try snapshot.validate(value.snapshot.*);
                return .{ .snapshot = try snapshot.dupe(gpa, value.snapshot.*), .at_ms = value.at_ms };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Ledger

pub const Ledger = struct {
    gpa: Allocator,
    io: Io,
    /// Null for a detached ledger (`openDetached`).
    profile: ?*Profile,
    sink: ?host.SessionSink,
    kind: markers.Kind,
    session_id: []u8,
    origin: []u8,
    limits: core.Limits,
    /// The host gave a lookup transport. Without one, credentials only name
    /// the identity lookup entries are written with.
    can_look_up: bool,
    /// Written only under the worker's checkpoint lock.
    buffers: checkpoint.Buffers = .{},
    /// The error the last marker write gave (`@intFromError`), 0 when it
    /// succeeded: the cause behind a `CheckpointFailed` from a marker.
    marker_error: std.atomic.Value(u16) = .init(0),
    context_lock: Io.Mutex = .init,
    context: Context = .{},
    worker: worker.Worker,

    pub const Options = struct {
        session_id: []const u8,
        marker: MarkerKind = .v1,
        /// Null for a new session.
        saved: ?Saved = null,
        /// A new session's start, when there is no saved snapshot.
        start: core.Start = .fresh,
        sink: host.SessionSink,
        /// fx's `/v1/generation` transport. Null when the host can't look
        /// generations up: lookup entries then wait, as they do signed out.
        lookup: ?host.Lookup = null,
        /// The Gateway origin the session's calls go to.
        origin: []const u8 = default_origin,
        wall_start: WallStart = .open,
        limits: Limits = .{},
        schedule: Schedule = .{},
        tracer: ?*trace.Writer = null,
        /// The ledger core's trace instance; dev tools name a restarted
        /// process differently. Borrowed for the ledger's life.
        trace_instance: []const u8 = "session",
    };

    pub const DetachedOptions = struct {
        saved: ?Saved = null,
        start: core.Start = .fresh,
        /// Persists checkpoints when set; a detached ledger without one
        /// lives in memory only.
        sink: ?host.SessionSink = null,
        wall_start: WallStart = .open,
        limits: Limits = .{},
    };

    /// A ledger with no profile: it never touches `~/.fx`, starts no task,
    /// and looks nothing up. Exact calls settle into its session totals at
    /// once, as in a session nothing publishes to; lookup entries wait.
    /// For single-threaded hosts and sessions whose usage is counted
    /// nowhere else. Rolling views are refused.
    pub fn openDetached(gpa: Allocator, io: Io, options: DetachedOptions) !*Ledger {
        const l = try gpa.create(Ledger);
        errdefer gpa.destroy(l);
        const session_id = try gpa.dupe(u8, "");
        errdefer gpa.free(session_id);
        const origin = try gpa.dupe(u8, default_origin);
        errdefer gpa.free(origin);
        var limits = options.limits;
        limits.bridge_origin_bytes = @intCast(origin.len);
        l.* = .{
            .gpa = gpa,
            .io = io,
            .profile = null,
            .sink = options.sink,
            .kind = .v1,
            .session_id = session_id,
            .origin = origin,
            .limits = limits,
            .can_look_up = false,
            .worker = undefined,
        };
        try l.initWorker(options.saved, false, .{
            .limits = limits,
            .start = options.start,
            .lookup = l.noLookup(),
            .sink = .{ .context = l, .vtable = &Ledger.sink_vtable },
            .publisher = .{ .context = l, .vtable = &Ledger.detached_publisher_vtable },
            .inline_only = true,
            .wall_start = options.wall_start,
        });
        // A restored backlog settles now.
        l.worker.publishOwed();
        return l;
    }

    fn initWorker(l: *Ledger, saved: ?Saved, marker: bool, options: worker.Options) !void {
        var parsed: ?Saved.Parsed = if (saved) |value| try value.parse(l.gpa) else null;
        defer if (parsed) |*value| value.deinit(l.gpa);
        const restore_buffers = try l.gpa.create(checkpoint.RestoreBuffers);
        defer l.gpa.destroy(restore_buffers);
        var with_restore = options;
        if (parsed) |*value| {
            const restored = try checkpoint.restoredOf(&value.snapshot, value.at_ms, restore_buffers);
            with_restore.restore = .{ .saved = restored, .saved_at_ms = value.at_ms, .marker = marker };
        }
        try l.worker.init(l.gpa, l.io, with_restore);
    }

    /// What `setCredential` says about the credential, kept for the lookup
    /// entries of later calls.
    pub const Credential = struct {
        credential: host.Credential,
        source: ?CredentialSource = null,
        /// The Vercel team lookups are scoped to.
        team: ?[]const u8 = null,
        account_id: ?[]const u8 = null,
    };

    const Context = struct {
        source: ?CredentialSource = null,
        /// The persisted credential identity (`authorityIdentity`), never
        /// derived from the secret.
        identity: ?core.Digest = null,
        team: Text(core.max_team_bytes) = .{},
        account: Text(core.max_account_bytes) = .{},
        /// The newest completed call's context use (`Call.observeContext`).
        context_sequence: core.Sequence = 0,
        context_used: ?u64 = null,
    };

    /// Joins the worker after a bounded final publish and checkpoint, then
    /// frees the ledger. The ledger is gone even when this fails.
    pub fn close(l: *Ledger) worker.CloseError!void {
        const result = l.worker.close();
        l.worker.deinit();
        const gpa = l.gpa;
        gpa.free(l.session_id);
        gpa.free(l.origin);
        gpa.destroy(l);
        return result;
    }

    /// Reserves a sequence; the checkpoint saying a call is in flight is
    /// durable before this returns, so network I/O may start. When that
    /// checkpoint fails the call has already ended unbilled.
    pub fn begin(l: *Ledger, provider: Provider) worker.ReportError!Call {
        const now = wallMs(l.io);
        const transition = try l.step(.{ .begin = provider });
        return .{
            .ledger = l,
            .sequence = transition.call,
            .provider = provider,
            .started_at_ms = @max(now, 0),
            .started = Io.Clock.Timestamp.now(l.io, .awake),
        };
    }

    pub fn setCredential(l: *Ledger, credential: Credential) (worker.CredentialError || error{InvalidCredentialContext})!void {
        const team = credential.team orelse "";
        const account = credential.account_id orelse "";
        if (team.len > core.max_team_bytes or account.len > core.max_account_bytes) return error.InvalidCredentialContext;
        // Checked first, so an invalid secret changes nothing.
        _ = try credential.credential.digest();
        {
            l.context_lock.lockUncancelable(l.io);
            defer l.context_lock.unlock(l.io);
            l.context.source = credential.source;
            l.context.identity = if (credential.source) |source| authorityIdentity(source, credential.account_id) else null;
            l.context.team.set(team);
            l.context.account.set(account);
        }
        if (l.can_look_up) try l.worker.setCredential(credential.credential);
    }

    /// Activity the host measured outside calls: wall time is the module's,
    /// code lines are the host's. Durable with the next checkpoint, or now
    /// with `flushActivity`.
    pub fn recordLines(l: *Ledger, added: u64, removed: u64) void {
        l.worker.recordActivity(.{ .lines_added = added, .lines_removed = removed });
    }

    /// The host couldn't count some code lines.
    pub fn markCodeIncomplete(l: *Ledger) void {
        l.worker.recordActivity(.{ .code_incomplete = true });
    }

    /// Persists a checkpoint now if activity changed since the last one.
    pub fn flushActivity(l: *Ledger) error{ Closed, CheckpointFailed }!void {
        return l.worker.flushActivity();
    }

    /// Waits up to `budget_ms` for lookups in flight or due now, for a host
    /// that closes right after its last call (`fx ask`). Then `close`.
    pub fn awaitLookups(l: *Ledger, budget_ms: u32) void {
        l.worker.awaitLookups(budget_ms);
    }

    /// Input plus output tokens of the newest completed call that reported
    /// both, or null. Runtime only: a restored session doesn't know it.
    pub fn liveContext(l: *Ledger) ?u64 {
        l.context_lock.lockUncancelable(l.io);
        defer l.context_lock.unlock(l.io);
        return l.context.context_used;
    }

    /// The session view, or a rolling view through the profile. The caller
    /// owns the result.
    pub fn view(l: *Ledger, gpa: Allocator, scope: Scope, now_ms: i64, turn: TurnUsage) !View {
        if (scope != .session) {
            const profile = l.profile orelse return error.NoProfile;
            return profile.view(gpa, scope, now_ms);
        }
        var rows: [Limits.ceiling]core.ModelRow = undefined;
        const live = l.worker.view(&rows);
        var copy: core.Ledger = try .init(gpa, l.limits, .fresh);
        defer copy.deinit(gpa);
        l.worker.copyLedger(&copy);
        const buffers = try gpa.create(checkpoint.Buffers);
        defer gpa.destroy(buffers);
        const times: checkpoint.Times = .{ .at_ms = now_ms, .opened_at_ms = l.worker.openedAt() };
        const snap = checkpoint.snapshotOf(&copy, times, "", buffers);
        var session = try report.sessionViewFromSnapshot(gpa, &snap, now_ms, .fromLedger(live.unpriced), turn);
        const open = copy.active.items.len;
        if (open == 0) return session;
        // `completeness` keeps the checkpoint's reading, so ACP reports no
        // cost mid-call; the dashboard shows what the session settles to.
        var settled_times = times;
        settled_times.live = true;
        const settled = checkpoint.snapshotOf(&copy, settled_times, "", buffers);
        session.in_flight = std.math.cast(u32, open) orelse std.math.maxInt(u32);
        session.settled_completeness = report.billingCompleteness(settled.billing);
        if (session.session_activity) |*activity| activity.api_duration_complete = settled.api_duration_complete;
        return session;
    }

    /// The session as a checkpoint would persist it now, for a state blob or
    /// a new session that copies this one. The caller owns the result.
    pub fn snapshot(l: *Ledger, gpa: Allocator) !Snapshot {
        var copy: core.Ledger = try .init(gpa, l.limits, .fresh);
        defer copy.deinit(gpa);
        l.worker.copyLedger(&copy);
        const buffers = try gpa.create(checkpoint.Buffers);
        defer gpa.destroy(buffers);
        const snap = checkpoint.snapshotOf(&copy, .{ .at_ms = wallMs(l.io), .opened_at_ms = l.worker.openedAt() }, l.origin, buffers);
        return snapshot_codec.dupe(gpa, snap);
    }

    pub fn stats(l: *Ledger) Stats {
        return l.worker.stats();
    }

    /// Why the last marker write failed, such as `error.NoSpaceLeft`, or
    /// null when it succeeded. A host reports this in place of
    /// `CheckpointFailed`, which says only that the checkpoint isn't durable.
    pub fn markerFailure(l: *Ledger) ?anyerror {
        const code = l.marker_error.load(.acquire);
        if (code == 0) return null;
        return @errorFromInt(code);
    }

    fn step(l: *Ledger, event: worker.CallEvent) worker.ReportError!core.Transition {
        const transition = try l.worker.report(event);
        if (l.profile == null) l.worker.publishOwed();
        return transition;
    }

    fn observeContext(l: *Ledger, sequence: core.Sequence, used: ?u64) void {
        l.context_lock.lockUncancelable(l.io);
        defer l.context_lock.unlock(l.io);
        if (sequence < l.context.context_sequence) return;
        l.context.context_sequence = sequence;
        l.context.context_used = used;
    }

    // Host seams -----------------------------------------------------------

    const sink_vtable: worker.Sink.VTable = .{ .persist = persist };

    fn persist(context: *anyopaque, frozen: *const worker.Checkpoint) worker.Sink.PersistError!void {
        const l: *Ledger = @ptrCast(@alignCast(context));
        const sink = l.sink orelse return;
        const snap = checkpoint.snapshotOf(frozen.ledger, .{ .at_ms = frozen.at_ms, .opened_at_ms = frozen.opened_at_ms }, l.origin, &l.buffers);
        const saved: host.Checkpoint = .{ .number = frozen.number, .at_ms = frozen.at_ms, .snapshot = &snap };
        return sink.persist(&saved);
    }

    const publisher_vtable: worker.Publisher.VTable = .{
        .publish = publishFact,
        .publish_pending = publishPending,
        .publish_incident = publishIncident,
    };

    /// No profile: a fact is accepted in memory, so it settles into the
    /// session totals; incidents stay in the session's checkpoint.
    const detached_publisher_vtable: worker.Publisher.VTable = .{
        .publish = acceptFact,
        .publish_pending = null,
        .publish_incident = null,
    };

    fn acceptFact(_: *anyopaque, _: *const core.Fact) worker.Publisher.PublishError!worker.Publisher.Answer {
        return .appended;
    }

    fn publishFact(context: *anyopaque, fact: *const core.Fact) worker.Publisher.PublishError!worker.Publisher.Answer {
        const l: *Ledger = @ptrCast(@alignCast(context));
        const outcome = try l.profile.?.append(.{ .generation = .{
            .id = fact.id.slice(),
            .created_at_ms = fact.created_at_ms,
            .model = fact.model,
            .input_tokens = fact.input_tokens,
            .output_tokens = fact.output_tokens,
            .cache_read_tokens = fact.cache_read_tokens,
            .cache_write_tokens = fact.cache_write_tokens,
            .reasoning_tokens = fact.reasoning_tokens,
            .billable_web_search_calls = fact.billable_web_search_calls,
            .total_cost = fact.total_cost,
        } });
        return switch (outcome) {
            .appended => .appended,
            .duplicate => .duplicate,
            .conflict => .conflict,
        };
    }

    fn publishPending(context: *anyopaque, record: *const worker.Publisher.PendingRecord) worker.Publisher.PublishError!void {
        const l: *Ledger = @ptrCast(@alignCast(context));
        // A second variant of an id is the store's business (an incident);
        // either way the record is down.
        _ = try l.profile.?.append(.{ .pending = .{ .id = record.id, .observed_at_ms = record.observed_at_ms } });
    }

    fn publishIncident(context: *anyopaque, incident: core.Incident) worker.Publisher.PublishError!void {
        const l: *Ledger = @ptrCast(@alignCast(context));
        _ = try l.profile.?.append(.{ .incident = .{
            .occurred_at_ms = incident.occurred_at_ms,
            .completeness = switch (incident.completeness) {
                .pending => .pending,
                .incomplete => .incomplete,
            },
        } });
    }

    const markers_vtable: worker.Markers.VTable = .{ .prepare = prepareMarker, .clear = clearMarker };

    fn prepareMarker(context: *anyopaque, input: worker.Markers.Input) worker.Markers.Error!i64 {
        const l: *Ledger = @ptrCast(@alignCast(context));
        const p = l.profile.?;
        var cause: ?anyerror = null;
        var probe = p.probe;
        probe.cause = &cause;
        const prepared = markers.prepareCheckpoint(p.io, p.home, l.kind, l.session_id, .{
            .now_ms = input.now_ms,
            .saved_at_ms = input.saved_at_ms,
            .saved_owes = input.saved_owes,
            .next_owes = input.next_owes,
        }, probe) catch |err| return l.markerFailed(cause orelse err);
        // Only a marker made durable answers an earlier failure; a checkpoint
        // that owes nothing writes none.
        if (input.next_owes) l.marker_error.store(0, .release);
        return prepared.at_ms;
    }

    fn clearMarker(context: *anyopaque) worker.Markers.Error!void {
        const l: *Ledger = @ptrCast(@alignCast(context));
        const p = l.profile.?;
        _ = markers.clear(p.io, p.home, l.kind, l.session_id, p.probe) catch |err| return l.markerFailed(err);
        l.marker_error.store(0, .release);
    }

    fn markerFailed(l: *Ledger, err: anyerror) error{MarkerFailed} {
        l.marker_error.store(@intFromError(err), .release);
        return error.MarkerFailed;
    }

    /// For a host with no lookup transport: no origin is trusted. Lookups
    /// only run with a credential, which such a host never sets.
    fn noLookup(l: *Ledger) host.Lookup {
        return .{ .context = l, .vtable = &no_lookup_vtable };
    }

    const no_lookup_vtable: host.Lookup.VTable = .{ .trusted = trustNothing, .fetch = fetchNothing };

    fn trustNothing(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn fetchNothing(_: *anyopaque, _: *const host.Lookup.Request, _: []u8) host.Lookup.FetchError!host.Lookup.Response {
        return error.Transport;
    }
};

/// The credential identity fx persists on lookup entries, byte for byte
/// what fx's credential authority derives: Gateway sources name their
/// credential slot, provider subscriptions their account. It is never
/// derived from the secret. Null for a subscription without an account.
fn authorityIdentity(source: CredentialSource, account_id: ?[]const u8) ?core.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-credential-authority-v1\x00");
    hash.update(@tagName(source));
    switch (source) {
        .vercel_oidc_token,
        .ai_gateway_api_key,
        .fx_login,
        .stored_key,
        .host_managed,
        .configured,
        => hash.update("\x00slot\x00"),
        .chatgpt_subscription,
        .grok_subscription,
        => {
            const account = account_id orelse return null;
            if (account.len == 0) return null;
            hash.update("\x00account\x00");
            hash.update(account);
        },
    }
    return hash.finalResult();
}

/// A short string kept inline.
fn Text(comptime max: usize) type {
    return struct {
        bytes: [max]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn set(text: *Self, value: []const u8) void {
            @memcpy(text.bytes[0..value.len], value);
            text.len = value.len;
        }

        fn get(text: *const Self) ?[]const u8 {
            return if (text.len == 0) null else text.bytes[0..text.len];
        }
    };
}

// ---------------------------------------------------------------------------
// Call

/// One model call. `finish` or `finishExact` ends it exactly once.
pub const Call = struct {
    ledger: *Ledger,
    sequence: core.Sequence,
    provider: Provider,
    started_at_ms: i64,
    started: Io.Clock.Timestamp,
    observation: receipt.Observation = .{},
    /// Set by `observeContext`; applied when the call completes.
    context: ?struct { used: ?u64 } = null,

    pub const Outcome = enum {
        completed,
        /// Failed before anything was sent: not billed.
        failed_unbilled,
        /// May have been sent and billed.
        possibly_sent,
        /// Cancelled after it may have been sent. A generation id seen so
        /// far is still looked up.
        cancelled,
    };

    /// One SSE `data:` payload, in order. The module keeps what it needs.
    pub fn gatewayEvent(call: *Call, event_json: []const u8) void {
        // Out of memory fails the observation: no receipt, and the id seen
        // so far is still looked up.
        call.observation.observe(call.ledger.gpa, event_json) catch {};
    }

    /// One SSE `data:` payload the host already parsed, in order. The value
    /// is borrowed for the call.
    pub fn gatewayValue(call: *Call, event: std.json.Value) void {
        call.observation.observeParsed(call.ledger.gpa, event) catch {};
    }

    /// The provider's token counts for this call, for `Ledger.liveContext`.
    /// Applied only if the call completes.
    pub fn observeContext(call: *Call, input_tokens: ?u64, output_tokens: ?u64) void {
        const input = input_tokens orelse return call.setContext(null);
        const output = output_tokens orelse return call.setContext(null);
        call.setContext(std.math.add(u64, input, output) catch null);
    }

    fn setContext(call: *Call, used: ?u64) void {
        call.context = .{ .used = used };
    }

    fn applyContext(call: *const Call) void {
        const context = call.context orelse return;
        call.ledger.observeContext(call.sequence, context.used);
    }

    pub fn finish(call: *Call, outcome: Outcome) worker.ReportError!core.Transition {
        const l = call.ledger;
        defer call.observation.deinit(l.gpa);
        call.recordApiTime();
        if (outcome == .failed_unbilled) return l.step(.{ .finish_unbilled = call.sequence });
        if (outcome == .completed) call.applyContext();
        if (call.observation.receipt(call.started_at_ms)) |found| {
            if (core.GenerationId.parse(found.generation_id)) |id| {
                const fact: core.Fact = .{
                    .id = id,
                    .created_at_ms = found.created_at_ms,
                    .model = found.model,
                    .total_cost = found.total_cost,
                    .input_tokens = found.input_tokens,
                    .output_tokens = found.output_tokens,
                    .cache_read_tokens = found.cache_read_tokens,
                    .cache_write_tokens = found.cache_write_tokens,
                    .reasoning_tokens = found.reasoning_tokens,
                    .billable_web_search_calls = found.billable_web_search_calls,
                };
                if (fact.validate()) |_| {
                    return l.step(.{ .finish_exact = .{ .sequence = call.sequence, .fact = fact } });
                } else |_| {}
            } else |_| {}
        }
        const now = @max(wallMs(l.io), 0);
        switch (call.observation.identity()) {
            .valid => |text| if (core.GenerationId.parse(text)) |id| {
                l.context_lock.lockUncancelable(l.io);
                defer l.context_lock.unlock(l.io);
                const context = &l.context;
                return l.step(.{ .finish_lookup = .{ .sequence = call.sequence, .request = .{
                    .id = id,
                    .origin = l.origin,
                    .team = context.team.get(),
                    .credential_source = context.source,
                    .credential_identity = context.identity,
                    .account_id = context.account.get(),
                    .observed_at_ms = now,
                } } });
            } else |_| {},
            .none, .invalid => {},
        }
        return l.step(.{ .finish_unpriced = .{ .sequence = call.sequence, .at_ms = now } });
    }

    /// Exact usage a subscription provider reported.
    pub const Exact = struct {
        /// The provider's own id for the response; the generation id is
        /// derived from it (`subscriptionId`).
        external_id: []const u8,
        model: []const u8,
        /// When the provider reported it; the call's begin time when null.
        created_at_ms: ?i64 = null,
        total_cost: f64 = 0,
        input_tokens: u64 = 0,
        output_tokens: u64 = 0,
        cache_read_tokens: u64 = 0,
        cache_write_tokens: u64 = 0,
        reasoning_tokens: ?u64 = null,
    };

    /// Ends the call with a subscription's exact usage. An id or fact the
    /// ledger can't accept ends it unpriced, with an incident, so the call
    /// always ends.
    pub fn finishExact(call: *Call, exact: Exact) worker.ReportError!core.Transition {
        const l = call.ledger;
        defer call.observation.deinit(l.gpa);
        call.recordApiTime();
        call.applyContext();
        if (subscriptionId(call.provider, exact.external_id)) |id| {
            const fact: core.Fact = .{
                .id = id,
                .created_at_ms = exact.created_at_ms orelse call.started_at_ms,
                .model = exact.model,
                .total_cost = exact.total_cost,
                .input_tokens = exact.input_tokens,
                .output_tokens = exact.output_tokens,
                .cache_read_tokens = exact.cache_read_tokens,
                .cache_write_tokens = exact.cache_write_tokens,
                .reasoning_tokens = exact.reasoning_tokens,
            };
            if (fact.validate()) |_| {
                return l.step(.{ .finish_exact = .{ .sequence = call.sequence, .fact = fact } });
            } else |_| {}
        }
        return l.step(.{ .finish_unpriced = .{ .sequence = call.sequence, .at_ms = @max(wallMs(l.io), 0) } });
    }

    fn recordApiTime(call: *const Call) void {
        const elapsed = call.started.untilNow(call.ledger.io).raw.toMilliseconds();
        call.ledger.worker.recordActivity(.{ .api_ms = @intCast(@max(elapsed, 0)) });
    }
};

/// The generation id of a subscription call, as fx has always derived it:
/// `gen_` and the first 13 bytes of SHA-256(provider, 0x00, external id) in
/// uppercase hex. A Gateway id is its own id. Null for an external id fx
/// refuses (empty, over 8 KiB, not UTF-8, or with a control byte), and for
/// configured providers, which never report exact usage.
fn subscriptionId(provider: Provider, external_id: []const u8) ?core.GenerationId {
    switch (provider) {
        .gateway => return core.GenerationId.parse(external_id) catch null,
        .configured => return null,
        .codex, .grok => {},
    }
    if (external_id.len == 0 or external_id.len > 8 * 1024 or !std.unicode.utf8ValidateSlice(external_id)) return null;
    for (external_id) |byte| if (std.ascii.isControl(byte)) return null;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(provider));
    hash.update(&.{0});
    hash.update(external_id);
    hash.final(&digest);
    var bytes: [core.GenerationId.length]u8 = undefined;
    @memcpy(bytes[0..4], "gen_");
    bytes[4..].* = std.fmt.bytesToHex(digest[0..13].*, .upper);
    return core.GenerationId.parse(&bytes) catch unreachable;
}

// ---------------------------------------------------------------------------
// Dashboard views

/// Builds the three rolling views off the owner's thread, for the TUI
/// dashboard. `refresh`, `poll`, `view`, and `deinit` are called from one
/// thread; the load runs as a task when the host can run one, else inline.
pub const ViewLoader = struct {
    profile: *Profile,
    gpa: Allocator,
    lock: Io.Mutex = .init,
    task: ?Io.Future(void) = null,
    // Guarded by `lock`.
    loading: bool = false,
    finished: ?Result = null,
    // Owner thread only.
    current: ?[Scope.rolling.len]View = null,
    /// The views `poll` replaced, kept until the next `poll` so the owner
    /// can carry its selection over.
    retired: ?[Scope.rolling.len]View = null,
    last_error: ?ViewsError = null,

    pub const ViewsError = @typeInfo(@typeInfo(@TypeOf(Profile.views)).@"fn".return_type.?).error_union.error_set;

    const Result = union(enum) {
        ready: [Scope.rolling.len]View,
        failed: ViewsError,
    };

    pub const Transition = enum { none, ready, failed };

    pub fn init(profile: *Profile, gpa: Allocator) ViewLoader {
        return .{ .profile = profile, .gpa = gpa };
    }

    /// Waits for a load in progress, then frees every view.
    pub fn deinit(v: *ViewLoader) void {
        if (v.task) |*task| task.await(v.profile.io);
        if (v.finished) |*result| v.freeResult(result);
        if (v.current) |*views| v.freeViews(views);
        if (v.retired) |*views| v.freeViews(views);
        v.* = undefined;
    }

    /// Starts loading the views at `now_ms` unless a load is running.
    /// Returns whether it started one.
    pub fn refresh(v: *ViewLoader, now_ms: i64) bool {
        {
            v.lock.lockUncancelable(v.profile.io);
            defer v.lock.unlock(v.profile.io);
            if (v.loading) return false;
            v.loading = true;
        }
        // The last load cleared `loading` as its final step.
        if (v.task) |*done| done.await(v.profile.io);
        v.task = v.profile.io.concurrent(load, .{ v, now_ms }) catch blk: {
            load(v, now_ms);
            break :blk null;
        };
        return true;
    }

    fn load(v: *ViewLoader, now_ms: i64) void {
        const result: Result = if (v.profile.views(v.gpa, now_ms)) |views| .{ .ready = views } else |err| .{ .failed = err };
        v.lock.lockUncancelable(v.profile.io);
        defer v.lock.unlock(v.profile.io);
        if (v.finished) |*old| v.freeResult(old);
        v.finished = result;
        v.loading = false;
    }

    /// Whether a load is running.
    pub fn isLoading(v: *ViewLoader) bool {
        v.lock.lockUncancelable(v.profile.io);
        defer v.lock.unlock(v.profile.io);
        return v.loading;
    }

    /// What finished since the last poll. After `.ready`, `view` returns the
    /// new views, and the ones they replaced stay valid until the next poll.
    /// After `.failed`, the old views stay and `lastError` says why.
    pub fn poll(v: *ViewLoader) Transition {
        const result = blk: {
            v.lock.lockUncancelable(v.profile.io);
            defer v.lock.unlock(v.profile.io);
            const result = v.finished orelse return .none;
            v.finished = null;
            break :blk result;
        };
        if (v.retired) |*views| v.freeViews(views);
        v.retired = null;
        switch (result) {
            .ready => |views| {
                v.retired = v.current;
                v.current = views;
                v.last_error = null;
                return .ready;
            },
            .failed => |err| {
                v.last_error = err;
                return .failed;
            },
        }
    }

    /// The loaded view of a rolling scope, or null. Borrowed until the poll
    /// after the next `.ready`, or `deinit`.
    pub fn view(v: *const ViewLoader, scope: Scope) ?*const View {
        if (v.current) |*views| {
            for (Scope.rolling, 0..) |candidate, index| {
                if (candidate == scope) return &views[index];
            }
        }
        return null;
    }

    pub fn lastError(v: *const ViewLoader) ?ViewsError {
        return v.last_error;
    }

    fn freeViews(v: *ViewLoader, views: *[Scope.rolling.len]View) void {
        for (views) |*one| one.deinit(v.gpa);
    }

    fn freeResult(v: *ViewLoader, result: *Result) void {
        switch (result.*) {
            .ready => |*views| v.freeViews(views),
            .failed => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

test {
    _ = @import("checkpoint.zig");
    _ = @import("codec/record.zig");
    _ = @import("codec/snapshot.zig");
    _ = @import("core/ledger.zig");
    _ = @import("core/publish.zig");
    _ = @import("host.zig");
    _ = @import("io/durable.zig");
    _ = @import("io/markers.zig");
    _ = @import("io/profile.zig");
    _ = @import("io/worker.zig");
    _ = @import("receipt.zig");
    _ = @import("render.zig");
    _ = @import("testdata/dir.zig");
    _ = @import("report.zig");
    _ = @import("trace.zig");
}

const testing = std.testing;

const TestSink = struct {
    bytes: ?[]u8 = null,
    at_ms: i64 = 0,
    persists: u32 = 0,

    fn handle(s: *TestSink) host.SessionSink {
        return .{ .context = s, .vtable = &.{ .persist = persistTest } };
    }

    fn persistTest(context: *anyopaque, saved: *const host.Checkpoint) host.SessionSink.PersistError!void {
        const s: *TestSink = @ptrCast(@alignCast(context));
        const bytes = saved.encodeSidecar(testing.allocator, "sess-1") catch return error.PersistFailed;
        if (s.bytes) |old| testing.allocator.free(old);
        s.bytes = bytes;
        s.at_ms = saved.at_ms;
        s.persists += 1;
    }

    fn deinit(s: *TestSink) void {
        if (s.bytes) |bytes| testing.allocator.free(bytes);
    }

    fn source(s: *TestSink) host.RecoverySource {
        return .{ .context = s, .vtable = &.{ .load = load } };
    }

    fn load(context: *anyopaque, kind: host.RecoverySource.Kind, session_id: []const u8) ?host.RecoverySource.Saved {
        const s: *TestSink = @ptrCast(@alignCast(context));
        if (kind != .v1 or !std.mem.eql(u8, session_id, "sess-1")) return null;
        return .{ .bytes = s.bytes orelse return null, .updated_at_ms = s.at_ms };
    }
};

/// Every lookup answers 404, which retries.
const TestLookup = struct {
    fetches: std.atomic.Value(u32) = .init(0),

    fn handle(l: *TestLookup) host.Lookup {
        return .{ .context = l, .vtable = &.{ .trusted = trusted, .fetch = fetch } };
    }

    fn trusted(_: *anyopaque, _: []const u8) bool {
        return true;
    }

    fn fetch(context: *anyopaque, _: *const host.Lookup.Request, _: []u8) host.Lookup.FetchError!host.Lookup.Response {
        const l: *TestLookup = @ptrCast(@alignCast(context));
        _ = l.fetches.fetchAdd(1, .monotonic);
        return .{ .status = 404, .body_len = 0 };
    }
};

const test_id_event =
    \\{"type":"text-start","id":"t1","providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}
;
const test_finish =
    \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":130,"cacheRead":20,"cacheWrite":10},"outputTokens":{"total":25,"reasoning":5}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","gatewayCost":"0.0123","routing":{"canonicalSlug":"provider/canonical"}}}}
;

fn markerExists(io: Io, home: Io.Dir) !bool {
    return (try markers.read(io, home, .v1, "sess-1")) != null;
}

test "a read-only profile never creates ~/.fx and can't open a ledger" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_only });
    defer profile.deinit();
    var view = try profile.view(testing.allocator, .days_30, wallMs(testing.io));
    defer view.deinit(testing.allocator);
    try testing.expectEqual(report.Coverage.not_started, view.coverage);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".fx", .{}));
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};
    try testing.expectError(error.ReadOnlyProfile, profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle(), .lookup = lookup.handle() }));
    try testing.expectError(error.SessionScope, profile.view(testing.allocator, .session, 0));
}

test "an exact receipt is published once, its marker clears, and the session restores" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};

    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        call.gatewayEvent(test_finish);
        const finished = try call.finish(.completed);
        try testing.expectEqual(core.State.fact, finished.to);
    }
    try ledger.close();
    try testing.expect(!try markerExists(testing.io, tmp.dir));

    const now = wallMs(testing.io);
    var rolling = try profile.view(testing.allocator, .days_30, now + 1);
    defer rolling.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.complete, rolling.completeness);
    try testing.expectEqual(@as(f64, 0.0123), rolling.totals.?.total_cost);

    // The checkpoint holds the settled totals and owes nothing.
    var saved = try snapshot.parseSidecar(testing.allocator, sink.bytes.?);
    defer saved.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.0123), saved.snapshot.total_cost);
    try testing.expectEqual(@as(usize, 0), saved.snapshot.publication_backlog.len);
    try testing.expectEqual(@as(usize, 0), saved.snapshot.pending.len);

    // Reopened from the sidecar, the session view shows the same call.
    const again = try profile.openLedger(.{
        .session_id = "sess-1",
        .saved = .{ .sidecar = .{ .bytes = sink.bytes.?, .updated_at_ms = sink.at_ms } },
        .sink = sink.handle(),
        .lookup = lookup.handle(),
    });
    {
        errdefer again.close() catch {};
        var session = try again.view(testing.allocator, .session, now + 1, .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 0.0123), session.totals.?.total_cost);
        try testing.expectEqual(report.Completeness.complete, session.completeness);
    }
    try again.close();
    // Published once: the restore didn't publish it again.
    var after = try profile.view(testing.allocator, .days_30, now + 1);
    defer after.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.0123), after.totals.?.total_cost);
}

test "a cancelled call with an id waits for a lookup, keeps its marker, and profile views count it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var sink: TestSink = .{};
    defer sink.deinit();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write, .recovery = sink.source() });
    defer profile.deinit();
    var lookup: TestLookup = .{};

    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        const finished = try call.finish(.cancelled);
        try testing.expectEqual(core.State.lookup, finished.to);
        var session = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(report.Completeness.pending, session.completeness);
        // Signed out is waiting, not blocked (only a 401/403 blocks).
        try testing.expectEqual(@as(?core.UnpricedReason, .lookup_pending), session.unpriced.reason);
    }
    try ledger.close();
    // Signed out, so nothing was looked up, and the session still owes.
    try testing.expectEqual(@as(u32, 0), lookup.fetches.load(.monotonic));
    try testing.expect(try markerExists(testing.io, tmp.dir));

    var rolling = try profile.view(testing.allocator, .hours_24, wallMs(testing.io) + 1);
    defer rolling.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.pending, rolling.completeness);
    // The pending record and the marked session name the same id once.
    try testing.expectEqual(@as(u64, 1), rolling.unpriced.lookup_pending);
}

test "rolling views are incomplete but keep their totals when session storage is unsafe" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const Source = struct {
        readable: bool,
        fn handle(s: *@This()) host.RecoverySource {
            return .{ .context = s, .vtable = &.{ .load = load, .available = available } };
        }
        fn load(_: *anyopaque, _: host.RecoverySource.Kind, _: []const u8) ?host.RecoverySource.Saved {
            return null;
        }
        fn available(context: *anyopaque) bool {
            const s: *@This() = @ptrCast(@alignCast(context));
            return s.readable;
        }
    };
    var source: Source = .{ .readable = true };
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write, .recovery = source.handle() });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        call.gatewayEvent(test_finish);
        try testing.expectEqual(core.State.fact, (try call.finish(.completed)).to);
    }
    try ledger.close();
    const now = wallMs(testing.io) + 1;

    var readable = try profile.view(testing.allocator, .days_30, now);
    defer readable.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.complete, readable.completeness);

    source.readable = false;
    var unsafe = try profile.view(testing.allocator, .days_30, now);
    defer unsafe.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, unsafe.completeness);
    try testing.expectEqual(@as(f64, 0.0123), readable.totals.?.total_cost);
    try testing.expectEqual(readable.totals.?.total_cost, unsafe.totals.?.total_cost);
    try testing.expectEqual(@as(?u64, 1), unsafe.totals.?.request_count);
}

test "a failed marker write keeps its cause for the host, and a later success clears it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    defer ledger.close() catch {};
    try testing.expectEqual(@as(?anyerror, null), ledger.markerFailure());
    // A file where the marker directory belongs: the marker can't be written.
    tmp.dir.createDir(testing.io, ".fx", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fx/usage-recovery", .data = "" });
    // An active call may still produce a fact, so its begin needs a marker.
    try testing.expectError(error.CheckpointFailed, ledger.begin(.gateway));
    const cause = ledger.markerFailure() orelse return error.TestExpectedCause;
    try testing.expect(cause != error.MarkerFailed and cause != error.CheckpointFailed);

    try tmp.dir.deleteFile(testing.io, ".fx/usage-recovery");
    var again = try ledger.begin(.gateway);
    // Its marker is durable: the earlier cause no longer applies.
    try testing.expectEqual(@as(?anyerror, null), ledger.markerFailure());
    try testing.expectEqual(core.State.unbilled, (try again.finish(.failed_unbilled)).to);
    try testing.expectEqual(@as(?anyerror, null), ledger.markerFailure());
}

test "a reopened session looks its waiting entries up once a credential arrives" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};
    const first = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer first.close() catch {};
        var call = try first.begin(.gateway);
        call.gatewayEvent(test_id_event);
        try testing.expectEqual(core.State.lookup, (try call.finish(.completed)).to);
    }
    try first.close();
    try testing.expectEqual(@as(u32, 0), lookup.fetches.load(.monotonic));

    const again = try profile.openLedger(.{
        .session_id = "sess-1",
        .saved = .{ .sidecar = .{ .bytes = sink.bytes.?, .updated_at_ms = sink.at_ms } },
        .sink = sink.handle(),
        .lookup = lookup.handle(),
    });
    defer again.close() catch {};
    try again.setCredential(.{ .credential = .{ .bearer = "vck_key" }, .source = .ai_gateway_api_key });
    var waited: u32 = 0;
    while (lookup.fetches.load(.monotonic) == 0 and waited < 2000) : (waited += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expect(lookup.fetches.load(.monotonic) >= 1);
}

test "wall time counts from first use, from open, or from the session's creation" {
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const now = wallMs(testing.io);
    // Resumed: the saved wall time is replaced by the time since creation.
    var saved = snapshot.legacy_unavailable;
    saved.billing = .complete;
    saved.wall_duration_complete = true;
    // Longer than the bound below allows, so keeping it would show.
    saved.wall_duration_ms = 10 * 60_000;
    const resumed = try Ledger.openDetached(testing.allocator, testing.io, .{
        .saved = .{ .parsed = .{ .snapshot = &saved, .at_ms = now } },
        .wall_start = .{ .at = now - day_ms },
    });
    defer resumed.close() catch {};
    var copy = try resumed.snapshot(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(copy.wall_duration_ms >= day_ms and copy.wall_duration_ms < day_ms + 60_000);
    try testing.expect(copy.wall_duration_complete);

    // A session that predates usage gets a complete wall time from creation.
    const legacy = try Ledger.openDetached(testing.allocator, testing.io, .{ .start = .legacy, .wall_start = .{ .at = now - day_ms } });
    defer legacy.close() catch {};
    var legacy_copy = try legacy.snapshot(testing.allocator);
    defer legacy_copy.deinit(testing.allocator);
    try testing.expect(legacy_copy.wall_duration_complete and legacy_copy.wall_duration_ms >= day_ms);
    // A creation time in the future can't be counted from.
    const future = try Ledger.openDetached(testing.allocator, testing.io, .{
        .saved = .{ .parsed = .{ .snapshot = &saved, .at_ms = now } },
        .wall_start = .{ .at = now + day_ms },
    });
    defer future.close() catch {};
    var future_copy = try future.snapshot(testing.allocator);
    defer future_copy.deinit(testing.allocator);
    try testing.expect(!future_copy.wall_duration_complete);

    // First use: nothing counts until the session is used.
    const lazy = try Ledger.openDetached(testing.allocator, testing.io, .{ .wall_start = .first_use });
    defer lazy.close() catch {};
    try testing.io.sleep(.fromMilliseconds(30), .awake);
    var call = try lazy.begin(.gateway);
    _ = try call.finish(.failed_unbilled);
    var lazy_copy = try lazy.snapshot(testing.allocator);
    defer lazy_copy.deinit(testing.allocator);
    try testing.expect(lazy_copy.wall_duration_ms < 30);
}

test "without a lookup transport a credential only names the entries" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    defer ledger.close() catch {};
    try ledger.setCredential(.{ .credential = .{ .bearer = "vck_key" }, .source = .ai_gateway_api_key });
    var call = try ledger.begin(.gateway);
    call.gatewayEvent(test_id_event);
    _ = try call.finish(.completed);
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(u32, 0), ledger.stats().lookups);
    var session = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
    defer session.deinit(testing.allocator);
    // Waiting, as signed out: never refused as untrusted.
    try testing.expectEqual(report.Completeness.pending, session.completeness);
}

test "a begin whose checkpoint fails ends unbilled instead of staying in flight" {
    const Failing = struct {
        persists: u32 = 0,
        fail_at: u32,

        fn handle(s: *@This()) host.SessionSink {
            return .{ .context = s, .vtable = &.{ .persist = persist } };
        }

        fn persist(context: *anyopaque, _: *const host.Checkpoint) host.SessionSink.PersistError!void {
            const s: *@This() = @ptrCast(@alignCast(context));
            s.persists += 1;
            if (s.persists == s.fail_at) return error.PersistFailed;
        }
    };
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: Failing = .{ .fail_at = 1 };
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    defer ledger.close() catch {};
    try testing.expectError(error.CheckpointFailed, ledger.begin(.gateway));
    var saved = try ledger.snapshot(testing.allocator);
    defer saved.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), saved.settled_through_sequence);
    try testing.expectEqual(snapshot.Billing.complete, saved.billing);
}

test "subscription ids are byte-compatible with the ids fx already wrote" {
    // gen_ + uppercase hex of SHA-256(provider, 0x00, external id)[0..13].
    try testing.expectEqualStrings("gen_348F7F84E4855CFB5200CDA92D", subscriptionId(.codex, "resp_123").?.slice());
    try testing.expectEqualStrings("gen_684C29C88372386D274B614F95", subscriptionId(.grok, "resp_123").?.slice());
    try testing.expect(!std.mem.eql(u8, subscriptionId(.codex, "resp_123").?.slice(), subscriptionId(.codex, "resp_124").?.slice()));
    try testing.expectEqualStrings("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV", subscriptionId(.gateway, "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV").?.slice());
    try testing.expect(subscriptionId(.codex, "") == null);
    try testing.expect(subscriptionId(.codex, "resp\x01") == null);
    try testing.expect(subscriptionId(.configured, "resp_123") == null);
}

test "the persisted credential identity is fx's authority, never the secret" {
    var expected: core.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, "235d1f0275d1d4704a6813e1e661a25dffedfefefe200d7bee541cca81fbfe67");
    try testing.expectEqualSlices(u8, &expected, &authorityIdentity(.fx_login, null).?);
    try testing.expectEqualSlices(u8, &expected, &authorityIdentity(.fx_login, "ignored").?);
    _ = try std.fmt.hexToBytes(&expected, "0e5c498c1df280148a53f73b4722f0a5b602ca6ea599ca03eea8aad6a783ee39");
    try testing.expectEqualSlices(u8, &expected, &authorityIdentity(.chatgpt_subscription, "acct_1").?);
    try testing.expect(authorityIdentity(.grok_subscription, null) == null);
    try testing.expect(authorityIdentity(.grok_subscription, "") == null);

    // A lookup entry carries it, whatever the secret.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    {
        errdefer ledger.close() catch {};
        try ledger.setCredential(.{ .credential = .{ .bearer = "vck_secret" }, .source = .fx_login });
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        _ = try call.finish(.completed);
        var saved = try ledger.snapshot(testing.allocator);
        defer saved.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), saved.pending.len);
        _ = try std.fmt.hexToBytes(&expected, "235d1f0275d1d4704a6813e1e661a25dffedfefefe200d7bee541cca81fbfe67");
        try testing.expectEqualSlices(u8, &expected, &saved.pending[0].credential_identity.?);
        try testing.expectEqual(@as(?CredentialSource, .fx_login), saved.pending[0].credential_source);
    }
    try ledger.close();
}

test "a detached ledger settles exact calls in memory, starts no task, and writes nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ledger = try Ledger.openDetached(testing.allocator, testing.io, .{});
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        call.gatewayEvent(test_finish);
        call.observeContext(130, 25);
        const finished = try call.finish(.completed);
        try testing.expectEqual(core.State.fact, finished.to);
        var session = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(report.Completeness.complete, session.completeness);
        try testing.expectEqual(@as(f64, 0.0123), session.totals.?.total_cost);
        try testing.expectEqual(@as(?u64, 155), ledger.liveContext());
        try testing.expectError(error.NoProfile, ledger.view(testing.allocator, .days_30, 0, .{}));
        try testing.expectEqual(@as(u32, 0), ledger.stats().spawns);

        // A copy restored from its snapshot shows the same totals.
        var saved = try ledger.snapshot(testing.allocator);
        defer saved.deinit(testing.allocator);
        try testing.expectEqual(snapshot.Billing.complete, saved.billing);
        const again = try Ledger.openDetached(testing.allocator, testing.io, .{ .saved = .{ .parsed = .{ .snapshot = &saved, .at_ms = wallMs(testing.io) } } });
        defer again.close() catch {};
        var restored = try again.view(testing.allocator, .session, wallMs(testing.io), .{});
        defer restored.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 0.0123), restored.totals.?.total_cost);
        try testing.expectEqual(@as(?u64, null), again.liveContext());

        // Only a completed call moves the live context.
        var cancelled = try ledger.begin(.gateway);
        cancelled.observeContext(1, 1);
        _ = try cancelled.finish(.cancelled);
        try testing.expectEqual(@as(?u64, 155), ledger.liveContext());
    }
    try ledger.close();
    var it = tmp.dir.iterate();
    try testing.expect((try it.next(testing.io)) == null);
}

test "a call in flight reads incomplete, as a checkpoint does, and says what it settles to" {
    const ledger = try Ledger.openDetached(testing.allocator, testing.io, .{});
    defer ledger.close() catch {};
    var done = try ledger.begin(.gateway);
    done.gatewayEvent(test_id_event);
    done.gatewayEvent(test_finish);
    _ = try done.finish(.completed);

    var open = try ledger.begin(.gateway);
    var during = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
    defer during.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, during.completeness);
    try testing.expectEqual(@as(?f64, null), report.completeCost(&during));
    try testing.expectEqual(@as(u32, 1), during.in_flight);
    try testing.expectEqual(report.Completeness.complete, during.settled_completeness);
    try testing.expect(during.session_activity.?.api_duration_complete);
    try testing.expectEqual(@as(f64, 0.0123), during.totals.?.total_cost);

    _ = try open.finish(.failed_unbilled);
    var after = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
    defer after.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.complete, after.completeness);
    try testing.expectEqual(@as(u32, 0), after.in_flight);
}

test "a parsed event observes the same as its text" {
    const ledger = try Ledger.openDetached(testing.allocator, testing.io, .{});
    defer ledger.close() catch {};
    var call = try ledger.begin(.gateway);
    for ([_][]const u8{ test_id_event, test_finish }) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer parsed.deinit();
        call.gatewayValue(parsed.value);
    }
    try testing.expectEqual(core.State.fact, (try call.finish(.completed)).to);
}

test "a subscription id the ledger refuses still ends the call" {
    const ledger = try Ledger.openDetached(testing.allocator, testing.io, .{});
    defer ledger.close() catch {};
    var call = try ledger.begin(.codex);
    try testing.expectEqual(core.State.unpriced, (try call.finishExact(.{ .external_id = "", .model = "openai/gpt-5" })).to);
    var ok = try ledger.begin(.codex);
    try testing.expectEqual(core.State.fact, (try ok.finishExact(.{ .external_id = "resp_1", .model = "openai/gpt-5", .input_tokens = 3 })).to);
    var session = try ledger.view(testing.allocator, .session, wallMs(testing.io), .{});
    defer session.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, session.completeness);
    try testing.expectEqual(@as(u64, 3), session.totals.?.input_tokens);
}

test "lines are durable at flushActivity, and code completeness can be lost" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
    defer profile.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try profile.openLedger(.{ .session_id = "sess-1", .sink = sink.handle() });
    {
        errdefer ledger.close() catch {};
        ledger.recordLines(4, 2);
        try ledger.flushActivity();
        try testing.expectEqual(@as(u32, 1), sink.persists);
        try ledger.flushActivity();
        try testing.expectEqual(@as(u32, 1), sink.persists);
        ledger.markCodeIncomplete();
        try ledger.flushActivity();
    }
    try ledger.close();
    var saved = try snapshot.parseSidecar(testing.allocator, sink.bytes.?);
    defer saved.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 4), saved.snapshot.lines_added);
    try testing.expectEqual(@as(u64, 2), saved.snapshot.lines_removed);
    try testing.expect(!saved.snapshot.code_complete);
}

test "the view loader keeps old views on failure and carries them through a refresh" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_only });
    defer profile.deinit();
    var loader: ViewLoader = .init(&profile, testing.allocator);
    defer loader.deinit();
    try testing.expectEqual(ViewLoader.Transition.none, loader.poll());
    try testing.expect(loader.view(.days_30) == null);
    try testing.expect(loader.refresh(wallMs(testing.io)));
    while (loader.isLoading()) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(ViewLoader.Transition.ready, loader.poll());
    const first = loader.view(.days_7).?;
    try testing.expectEqual(Scope.days_7, first.scope);
    try testing.expect(loader.view(.session) == null);

    // A ledger file the store refuses: the refresh fails, the views stay.
    try tmp.dir.createDirPath(testing.io, ".fx");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fx/usage.jsonl", .data = "not json\n" });
    try testing.expect(loader.refresh(wallMs(testing.io)));
    while (loader.isLoading()) try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(ViewLoader.Transition.failed, loader.poll());
    try testing.expect(loader.lastError() != null);
    try testing.expect(loader.view(.days_7) == first);
}

test "an orphan marker is one incident at its protected time, not a gap in every window" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now = wallMs(testing.io);
    const day_ms = 24 * 60 * 60 * 1000;
    {
        var writer = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_write });
        defer writer.deinit();
        _ = try writer.append(.{ .incident = .{ .occurred_at_ms = now - 60 * day_ms, .completeness = .pending } });
    }
    _ = try markers.write(testing.io, tmp.dir, .v1, "gone", now - 20 * day_ms, .replace, .{});
    // No recovery source: the session behind the marker can't be read.
    var profile = Profile.init(testing.allocator, testing.io, .{ .home = tmp.dir, .mode = .read_only });
    defer profile.deinit();
    var day = try profile.view(testing.allocator, .hours_24, now);
    defer day.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.complete, day.completeness);
    var month = try profile.view(testing.allocator, .days_30, now);
    defer month.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, month.completeness);
}
