//! A session's usage for the runtime that owns the session (the TUI, `fx
//! ask`, each ACP session): the profile it publishes to, the session's ledger
//! in the usage module, and the dashboard's view loader. The host says which
//! session is current and where its checkpoints go; the module decides
//! everything about usage.
//!
//! The owner must not move once `bind` has run: the ledger and the loader
//! point back into it.

const std = @import("std");
const builtin = @import("builtin");
const usage_mod = @import("usage");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const stream_provider = @import("../agent/stream_provider.zig");

const Allocator = std.mem.Allocator;

/// A lookup transport and the Gateway origin lookup entries name.
pub const Lookup = struct {
    transport: usage_mod.host.Lookup,
    origin: *const fn () []const u8,
};

/// The session a ledger belongs to.
pub const Target = struct {
    /// Borrowed for the call.
    session_id: []const u8,
    marker: usage_mod.MarkerKind,
};

/// What the host plugs in. Every function may be called from the module's
/// worker task as well as the host's threads.
pub const Host = struct {
    context: *anyopaque,
    /// The current durable session, or null when nothing is persisted (the
    /// ledger is then detached and counts in memory only). Called with the
    /// owner's lock held: it must not take a lock that is held while
    /// calling into the owner.
    current_fn: *const fn (context: *anyopaque) ?Target,
    /// Persists one checkpoint of `session_id` durably. Called with the
    /// module's checkpoint lock held; must not call back into the owner.
    persist_fn: *const fn (context: *anyopaque, session_id: []const u8, checkpoint: *const usage_mod.host.Checkpoint) anyerror!void,
};

/// How marked sessions' saved usage is read for rolling views: the session
/// store for v1 sessions and the sessions-v2 adapter.
pub const RecoveryReaders = struct {
    /// The v1 session's usage as sidecar bytes, its update time, and the
    /// sidecar's modification time. The caller owns `bytes`.
    v1: *const fn (alloc: Allocator, home_path: []const u8, session_id: []const u8) anyerror!?RecoveredV1,
    /// The newest sessions-v2 `set usage` value. The caller owns it.
    v2: *const fn (alloc: Allocator, home_path: []const u8, session_id: []const u8) anyerror!?[]u8,
    /// False when the session store can't be opened safely, so rolling
    /// views are unknown even with no marked session. Null: always readable.
    storage_readable: ?*const fn (alloc: Allocator, home_path: []const u8) bool = null,
};

pub const RecoveredV1 = struct {
    bytes: []u8,
    updated_at_ms: i64,
    modified_ns: ?i128,
};

pub const Owner = struct {
    alloc: Allocator = undefined,
    host: ?Host = null,
    lookup: ?Lookup = null,
    home: ?std.Io.Dir = null,
    profile: ?usage_mod.Profile = null,
    recovery: Recovery = .{},
    ledger: ?*usage_mod.Ledger = null,
    /// The session the open ledger belongs to; empty when detached.
    session_id: std.ArrayList(u8) = .empty,
    /// What the next ledger restores, and when its wall time counts from.
    pending_saved: ?usage_mod.Snapshot = null,
    pending_saved_at_ms: i64 = 0,
    pending_start: usage_mod.Start = .fresh,
    wall_start: usage_mod.WallStart = .first_use,
    /// The error the host's last failed persist returned (`@intFromError`).
    persist_error: std.atomic.Value(u16) = .init(0),
    dashboard: ?usage_mod.ViewLoader = null,
    lock: std.Io.Mutex = .init,
    bound: bool = false,

    pub const BindOptions = struct {
        host: ?Host,
        /// The HOME that holds `.fx`; null keeps usage in memory only.
        home_path: ?[]const u8,
        lookup: ?Lookup,
        recovery: ?RecoveryReaders = null,
    };

    /// Places the owner: the host, the profile, and the lookup transport.
    /// Opens nothing but HOME; the ledger opens on first use.
    pub fn bind(self: *Owner, alloc: Allocator, options: BindOptions) void {
        self.alloc = alloc;
        self.bound = true;
        self.host = options.host;
        self.lookup = if (comptime builtin.os.tag == .wasi) null else options.lookup;
        if (comptime builtin.os.tag == .wasi) return;
        const home_path = options.home_path orelse return;
        if (self.profile != null) return;
        self.home = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home_path, .{ .iterate = true }) catch |err| {
            debug_trace.logf("usage", "profile unavailable reason={s}", .{@errorName(err)});
            return;
        };
        self.recovery = .{ .alloc = alloc, .home_path = alloc.dupe(u8, home_path) catch null, .readers = options.recovery };
        self.profile = usage_mod.Profile.init(alloc, io_mod.getIo(), .{
            .home = self.home.?,
            .mode = .read_write,
            .recovery = self.recovery.source(),
        });
    }

    pub fn deinit(self: *Owner) void {
        self.close();
        if (self.dashboard) |*loader| loader.deinit();
        self.dashboard = null;
        if (self.profile) |*profile| profile.deinit();
        self.profile = null;
        if (self.home) |dir| dir.close(io_mod.getIo());
        self.home = null;
        self.recovery.deinit();
        self.dropPendingSaved();
        if (self.bound) self.session_id.deinit(self.alloc);
        self.* = .{};
    }

    /// Closes the open ledger: a bounded final publish and checkpoint. The
    /// next use opens a ledger for the session current then.
    pub fn close(self: *Owner) void {
        if (!self.bound) return;
        const ledger = blk: {
            self.lock.lockUncancelable(io_mod.getIo());
            defer self.lock.unlock(io_mod.getIo());
            const ledger = self.ledger orelse return;
            self.ledger = null;
            break :blk ledger;
        };
        ledger.close() catch |err| debug_trace.logf(
            "usage",
            "usage ledger close left work for the next run session={s} reason={s}",
            .{ self.session_id.items, @errorName(err) },
        );
    }

    /// Closes the open ledger like `close`, and fails when its final
    /// checkpoint isn't durable, with the error the host's write gave. For
    /// hosts whose session close depends on usage being saved.
    pub fn settle(self: *Owner) !void {
        if (!self.bound) return;
        const ledger = blk: {
            self.lock.lockUncancelable(io_mod.getIo());
            defer self.lock.unlock(io_mod.getIo());
            const ledger = self.ledger orelse return;
            self.ledger = null;
            break :blk ledger;
        };
        const kept = ledger.snapshot(pending_alloc) catch null;
        ledger.close() catch |err| {
            // The session may stay open: its next ledger restores this one.
            if (kept) |value| self.keepForReopen(value);
            return self.beginError(err, null);
        };
        if (kept) |value| {
            var owned = value;
            owned.deinit(pending_alloc);
        }
    }

    /// The next ledger restores `carried` (owned by `pending_alloc`), and its
    /// wall time keeps counting from when the closed one started.
    fn keepForReopen(self: *Owner, carried: usage_mod.Snapshot) void {
        const now_ms = io_mod.milliTimestamp();
        // Even at 0 ms the wall clock has started: the next ledger must not
        // wait for another first use.
        if (carried.wall_duration_complete) {
            self.wall_start = .{ .at = now_ms -| @as(i64, @intCast(@min(carried.wall_duration_ms, std.math.maxInt(i64)))) };
        }
        self.dropPendingSaved();
        self.pending_saved = carried;
        self.pending_saved_at_ms = 0;
        self.pending_start = .fresh;
    }

    /// The host's first session has started: unless a ledger is open or a
    /// restored session set it, wall time counts from now.
    pub fn startWall(self: *Owner) void {
        if (self.ledger != null) return;
        if (self.wall_start == .first_use) self.wall_start = .{ .at = io_mod.milliTimestamp() };
    }

    /// A new session starts now (`/new`): its wall time counts from here.
    pub fn startFresh(self: *Owner) void {
        self.close();
        self.dropPendingSaved();
        self.pending_start = .fresh;
        self.wall_start = .{ .at = io_mod.milliTimestamp() };
    }

    /// A resumed session: the next ledger restores `saved` (borrowed; copied
    /// here), or starts as one that predates usage when null. Wall time
    /// counts from the session's creation. Opens at once when the owner is
    /// bound, so its waiting lookups and unpublished facts resume.
    pub fn restore(self: *Owner, saved: ?*const usage_mod.Snapshot, saved_at_ms: i64, created_at_ms: i64) !void {
        self.close();
        self.dropPendingSaved();
        if (saved) |value| {
            self.pending_saved = try usage_mod.snapshot.dupe(pending_alloc, value.*);
            self.pending_saved_at_ms = saved_at_ms;
            self.pending_start = .fresh;
        } else {
            self.pending_start = .legacy;
        }
        self.wall_start = .{ .at = created_at_ms };
        if (self.bound) _ = self.use();
    }

    /// Process exit: never wait on `usage.lock` held by another process.
    pub fn abandon(self: *Owner) void {
        if (self.profile) |*profile| profile.abandon();
    }

    /// The open ledger, opening one for the current session first. Null
    /// when the owner is not bound, or the ledger can't open (logged).
    pub fn use(self: *Owner) ?*usage_mod.Ledger {
        if (!self.bound) return null;
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.ledger) |ledger| {
            if (!self.promoteLocked(ledger)) return ledger;
        }
        const saved: ?usage_mod.Saved = if (self.pending_saved) |*value|
            .{ .parsed = .{ .snapshot = value, .at_ms = self.pending_saved_at_ms } }
        else
            null;
        const target: ?Target = if (self.host) |host| host.current_fn(host.context) else null;
        const opened = if (target != null and self.profile != null) blk: {
            const lookup = self.lookup;
            break :blk self.profile.?.openLedger(.{
                .session_id = target.?.session_id,
                .marker = target.?.marker,
                .saved = saved,
                .start = self.pending_start,
                .sink = self.sink(),
                .lookup = if (lookup) |value| value.transport else null,
                .origin = if (lookup) |value| value.origin() else usage_mod.default_origin,
                .wall_start = self.wall_start,
            });
        } else usage_mod.Ledger.openDetached(self.alloc, io_mod.getIo(), .{
            .saved = saved,
            .start = self.pending_start,
            .wall_start = self.wall_start,
        });
        const ledger = opened catch |err| {
            debug_trace.logf("usage", "usage ledger unavailable reason={s}", .{@errorName(err)});
            return null;
        };
        self.session_id.clearRetainingCapacity();
        if (target) |value| self.session_id.appendSlice(self.alloc, value.session_id) catch {
            // The sink then refuses: a checkpoint can't name its session.
            self.session_id.clearRetainingCapacity();
        };
        self.dropPendingSaved();
        // Saved state is in the ledger now; a later reopen is a new run.
        self.pending_start = .fresh;
        self.ledger = ledger;
        return ledger;
    }

    /// A ledger opened detached before the session was durable moves to
    /// the session once the host names it: its state carries over and its
    /// wall time keeps counting from when it started. True when the caller
    /// must open the session's ledger. Caller holds `lock`.
    fn promoteLocked(self: *Owner, ledger: *usage_mod.Ledger) bool {
        if (self.session_id.items.len != 0 or self.profile == null) return false;
        const host = self.host orelse return false;
        if (host.current_fn(host.context) == null) return false;
        const carried = ledger.snapshot(pending_alloc) catch |err| {
            debug_trace.logf("usage", "detached usage kept reason={s}", .{@errorName(err)});
            return false;
        };
        ledger.close() catch {};
        self.ledger = null;
        self.keepForReopen(carried);
        debug_trace.logf("usage", "detached usage moved to the durable session", .{});
        return true;
    }

    /// Persists a checkpoint now when activity changed since the last one,
    /// for hosts that settle a session's state before closing it.
    pub fn flush(self: *Owner) !void {
        const ledger = self.openLedger() orelse return;
        ledger.flushActivity() catch |err| return self.beginError(err, ledger);
    }

    /// Code lines a committed file change added and removed. Lines that
    /// can't be counted make code incomplete.
    pub fn recordLines(self: *Owner, added: usize, removed: usize) void {
        const ledger = self.use() orelse return;
        const added_u64 = std.math.cast(u64, added) orelse return ledger.markCodeIncomplete();
        const removed_u64 = std.math.cast(u64, removed) orelse return ledger.markCodeIncomplete();
        ledger.recordLines(added_u64, removed_u64);
    }

    /// For a host that exits right after its last call (`fx ask`): gives a
    /// lookup in flight or due now up to `budget_ms` before `settle`.
    pub fn awaitLookups(self: *Owner, budget_ms: u32) void {
        const ledger = self.openLedger() orelse return;
        ledger.awaitLookups(budget_ms);
    }

    /// Input plus output tokens of the newest completed call, or null.
    pub fn liveContext(self: *Owner) ?u64 {
        const ledger = self.openLedger() orelse return null;
        return ledger.liveContext();
    }

    /// The ledger if one is open, without opening one.
    fn openLedger(self: *Owner) ?*usage_mod.Ledger {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        return self.ledger;
    }

    /// The session's view now. The caller owns it.
    pub fn sessionView(self: *Owner, alloc: Allocator, turn: usage_mod.TurnUsage) !usage_mod.View {
        const ledger = self.use() orelse return error.UsageUnavailable;
        return ledger.view(alloc, .session, io_mod.milliTimestamp(), turn);
    }

    /// The session as a checkpoint would persist it now. The caller owns it.
    pub fn snapshot(self: *Owner, alloc: Allocator) !usage_mod.Snapshot {
        const ledger = self.use() orelse return error.UsageUnavailable;
        return ledger.snapshot(alloc);
    }

    /// What a session save embeds: the snapshot now, or null when this
    /// owner has no ledger to read (not bound, or it could not open).
    pub fn durableSnapshot(self: *Owner, alloc: Allocator) !?usage_mod.Snapshot {
        const ledger = self.use() orelse return null;
        return try ledger.snapshot(alloc);
    }

    /// The credential lookups run with, from the host's current auth.
    pub fn setCredential(self: *Owner, lease: ?types.CredentialLease) void {
        const ledger = self.use() orelse return;
        setLedgerCredential(ledger, lease);
    }

    /// The dashboard's loader, or null when there is no profile.
    pub fn dashboardLoader(self: *Owner) ?*usage_mod.ViewLoader {
        if (self.dashboard) |*loader| return loader;
        const profile = if (self.profile) |*value| value else return null;
        self.dashboard = .init(profile, self.alloc);
        return &self.dashboard.?;
    }

    /// What owns `pending_saved`: the same before and after `bind`, since a
    /// host may restore a session before the owner reaches its address.
    const pending_alloc = std.heap.c_allocator;

    /// The error a failed persist returned, once.
    fn takePersistError(self: *Owner) ?anyerror {
        const code = self.persist_error.swap(0, .acq_rel);
        if (code == 0) return null;
        return @errorFromInt(code);
    }

    /// A begin's checkpoint failed: the call ended unbilled and must not
    /// send. The caller gets the host's error, as fx always reported it.
    /// The cause behind a failed checkpoint, as fx reported it before usage
    /// moved into the module: the host's write error, else the marker's
    /// (such as `NoSpaceLeft`). `ledger` is null once it is closed.
    fn beginError(self: *Owner, err: anyerror, ledger: ?*usage_mod.Ledger) anyerror {
        if (err != error.CheckpointFailed) return err;
        if (self.takePersistError()) |cause| return cause;
        if (ledger) |open| if (open.markerFailure()) |cause| return cause;
        return err;
    }

    /// A finish took effect but its checkpoint isn't durable yet; the module
    /// retries it. As fx always has, only an error that says the session's
    /// writer can't be trusted reaches the caller.
    fn finishError(self: *Owner, err: anyerror) anyerror!void {
        if (err != error.CheckpointFailed) return err;
        const cause = self.takePersistError() orelse return;
        switch (cause) {
            error.SessionPersistenceUncertain,
            error.SessionWriterChanged,
            error.SessionWriterParked,
            error.SessionCommitFailed,
            => return cause,
            else => {},
        }
    }

    fn dropPendingSaved(self: *Owner) void {
        if (self.pending_saved) |*value| value.deinit(pending_alloc);
        self.pending_saved = null;
    }

    fn sink(self: *Owner) usage_mod.host.SessionSink {
        return .{ .context = self, .vtable = &sink_vtable };
    }

    const sink_vtable: usage_mod.host.SessionSink.VTable = .{ .persist = persistThunk };

    fn persistThunk(context: *anyopaque, checkpoint: *const usage_mod.host.Checkpoint) usage_mod.host.SessionSink.PersistError!void {
        const self: *Owner = @ptrCast(@alignCast(context));
        const host = self.host orelse return error.PersistFailed;
        if (self.session_id.items.len == 0) return error.PersistFailed;
        host.persist_fn(host.context, self.session_id.items, checkpoint) catch |err| {
            self.persist_error.store(@intFromError(err), .release);
            debug_trace.logf(
                "usage",
                "usage checkpoint not persisted session={s} number={d} reason={s}",
                .{ self.session_id.items, checkpoint.number, @errorName(err) },
            );
            return error.PersistFailed;
        };
    }
};

fn setLedgerCredential(ledger: *usage_mod.Ledger, lease: ?types.CredentialLease) void {
    const credential: usage_mod.Ledger.Credential = blk: {
        const value = lease orelse break :blk .{ .credential = .signed_out };
        const source = value.credentialSource();
        const transport: usage_mod.host.Credential = if (source) |known| switch (known) {
            .host_managed => .host_managed,
            // Subscriptions and configured providers can't look Gateway
            // generations up.
            .chatgpt_subscription, .grok_subscription, .configured => .signed_out,
            .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key => if (value.secret()) |secret| .{ .bearer = secret } else .signed_out,
        } else .signed_out;
        break :blk .{
            .credential = transport,
            .source = if (source) |known| moduleSource(known) else null,
            .team = value.tenant(),
            .account_id = value.accountId(),
        };
    };
    ledger.setCredential(credential) catch |err| debug_trace.logf(
        "usage",
        "usage credential not set reason={s}",
        .{@errorName(err)},
    );
}

/// fx's credential source as the usage module names it. Every fx source
/// must have one: a new one fails the build here.
fn moduleSource(source: types.CredentialSource) usage_mod.CredentialSource {
    return switch (source) {
        inline else => |tag| @field(usage_mod.CredentialSource, @tagName(tag)),
    };
}

/// The usage module's provider for a request's credential.
fn providerOf(lease: types.CredentialLease) usage_mod.Provider {
    const source = lease.credentialSource() orelse return .gateway;
    return switch (source) {
        .chatgpt_subscription => .codex,
        .grok_subscription => .grok,
        .configured => .configured,
        else => .gateway,
    };
}

/// The time a v1 `usage_checkpointed` event carries: the checkpoint's own,
/// and always after the session's newest event, as fx has always written it.
pub fn v1EventTime(at_ms: i64, updated_at_ms: i64) error{InvalidSessionFormat}!i64 {
    if (at_ms > updated_at_ms) return at_ms;
    return std.math.add(i64, updated_at_ms, 1) catch error.InvalidSessionFormat;
}

test "a v1 usage event is later than the checkpoint and the session's newest event" {
    try std.testing.expectEqual(@as(i64, 50), try v1EventTime(50, 40));
    try std.testing.expectEqual(@as(i64, 41), try v1EventTime(30, 40));
    try std.testing.expectEqual(@as(i64, 41), try v1EventTime(40, 40));
    try std.testing.expectError(error.InvalidSessionFormat, v1EventTime(1, std.math.maxInt(i64)));
}

test "a detached ledger's started wall clock keeps running once it moves to the session" {
    const State = struct {
        target: ?Target = null,
        fn current(context: *anyopaque) ?Target {
            const state: *@This() = @ptrCast(@alignCast(context));
            return state.target;
        }
        fn persist(_: *anyopaque, _: []const u8, _: *const usage_mod.host.Checkpoint) anyerror!void {}
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var state: State = .{};
    var owner: Owner = .{};
    defer owner.deinit();
    owner.bind(alloc, .{
        .host = .{ .context = &state, .current_fn = State.current, .persist_fn = State.persist },
        .home_path = home,
        .lookup = null,
    });

    // A fresh session's first state is built before the session exists.
    var first = try owner.snapshot(alloc);
    first.deinit(alloc);
    // The session appears; a use that takes no snapshot moves usage to it.
    state.target = .{ .session_id = "session-1", .marker = .v1 };
    try std.testing.expect(owner.use() != null);
    io_mod.sleep(40 * std.time.ns_per_ms);
    var later = try owner.snapshot(alloc);
    defer later.deinit(alloc);
    try std.testing.expect(later.wall_duration_complete);
    try std.testing.expect(later.wall_duration_ms >= 40);
}

test "a fresh session's wall time counts from startWall, a restored one from its creation" {
    const alloc = std.testing.allocator;
    var fresh: Owner = .{};
    defer fresh.deinit();
    fresh.bind(alloc, .{ .host = null, .home_path = null, .lookup = null });
    fresh.startWall();
    io_mod.sleep(40 * std.time.ns_per_ms);
    // The first use comes later; the wall clock was already running.
    var first = try fresh.snapshot(alloc);
    defer first.deinit(alloc);
    try std.testing.expect(first.wall_duration_complete);
    try std.testing.expect(first.wall_duration_ms >= 40);

    var restored: Owner = .{};
    defer restored.deinit();
    restored.bind(alloc, .{ .host = null, .home_path = null, .lookup = null });
    const created_at_ms = io_mod.milliTimestamp() - 60 * std.time.ms_per_min;
    try restored.restore(null, 0, created_at_ms);
    restored.startWall();
    var resumed = try restored.snapshot(alloc);
    defer resumed.deinit(alloc);
    try std.testing.expect(resumed.wall_duration_ms >= 60 * std.time.ms_per_min);
}

/// One model call, from admission to its end, for every producer.
pub const Invocation = struct {
    owner: *Owner,
    call: usage_mod.Call,

    /// Reserves the call; its checkpoint is durable before this returns, so
    /// network I/O may start. Null when the session records no usage.
    pub fn begin(owner: ?*Owner, credential: types.CredentialLease) !?Invocation {
        const self_owner = owner orelse return null;
        const ledger = self_owner.use() orelse return null;
        const provider = providerOf(credential);
        // Only Gateway entries are looked up, so only a Gateway call's
        // credential is the one lookups run with.
        if (provider == .gateway) setLedgerCredential(ledger, credential);
        const call = ledger.begin(provider) catch |err| return self_owner.beginError(err, ledger);
        return .{ .owner = self_owner, .call = call };
    }

    /// Hands the call every Gateway SSE event. The invocation must not move
    /// while the stream runs.
    pub fn tap(self: *Invocation) stream_provider.GatewayEventTap {
        return .{ .context = &self.call, .observe_fn = observe };
    }

    fn observe(context: *anyopaque, event: std.json.Value) void {
        const call: *usage_mod.Call = @ptrCast(@alignCast(context));
        call.gatewayValue(event);
    }

    /// The provider answered with a failure status: not billed.
    pub fn rejected(self: *Invocation) !void {
        _ = self.call.finish(.failed_unbilled) catch |err| return self.owner.finishError(err);
    }

    /// The transport failed. Possibly sent means it may have been billed; a
    /// generation id seen so far is looked up.
    pub fn failed(self: *Invocation, err: anyerror, possibly_sent: bool) !void {
        const outcome: usage_mod.Call.Outcome = if (!possibly_sent)
            .failed_unbilled
        else if (err == error.Cancelled)
            .cancelled
        else
            .possibly_sent;
        _ = self.call.finish(outcome) catch |finish_err| return self.owner.finishError(finish_err);
    }

    /// The provider completed. Subscriptions report their own exact usage;
    /// Gateway calls are priced from the events the call saw.
    pub fn completed(self: *Invocation, completion: types.ModelCompletion) !void {
        self.call.observeContext(completion.usage.input_tokens, completion.usage.output_tokens);
        const result = if (completion.subscription_usage) |exact| blk: {
            const external_id = completion.generation_id orelse break :blk self.call.finish(.completed);
            break :blk self.call.finishExact(.{
                .external_id = external_id,
                .model = exact.model,
                .created_at_ms = exact.created_at_ms,
                .input_tokens = exact.input_tokens,
                .output_tokens = exact.output_tokens,
                .cache_read_tokens = exact.cache_read_tokens,
                .cache_write_tokens = exact.cache_write_tokens,
                .reasoning_tokens = exact.reasoning_tokens,
            });
        } else self.call.finish(.completed);
        _ = result catch |err| return self.owner.finishError(err);
    }
};

/// Reads marked sessions' saved usage for rolling views.
pub const Recovery = struct {
    alloc: Allocator = undefined,
    home_path: ?[]u8 = null,
    readers: ?RecoveryReaders = null,
    lock: std.Io.Mutex = .init,
    /// The bytes the last `load` returned.
    held: ?[]u8 = null,

    pub fn source(self: *Recovery) usage_mod.host.RecoverySource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn deinit(self: *Recovery) void {
        if (self.held) |bytes| self.alloc.free(bytes);
        if (self.home_path) |path| self.alloc.free(path);
        self.* = .{};
    }

    const vtable: usage_mod.host.RecoverySource.VTable = .{ .load = load, .available = available };

    fn available(context: *anyopaque) bool {
        const self: *Recovery = @ptrCast(@alignCast(context));
        const home = self.home_path orelse return true;
        const read = self.readers orelse return true;
        const check = read.storage_readable orelse return true;
        return check(self.alloc, home);
    }

    fn load(context: *anyopaque, kind: usage_mod.host.RecoverySource.Kind, session_id: []const u8) ?usage_mod.host.RecoverySource.Saved {
        const self: *Recovery = @ptrCast(@alignCast(context));
        const home = self.home_path orelse return null;
        const read = self.readers orelse return null;
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (self.held) |bytes| self.alloc.free(bytes);
        self.held = null;
        switch (kind) {
            .v1 => {
                const loaded = (read.v1(self.alloc, home, session_id) catch |err| {
                    debug_trace.logf("usage", "usage recovery unreadable session={s} reason={s}", .{ session_id, @errorName(err) });
                    return null;
                }) orelse return null;
                self.held = loaded.bytes;
                return .{ .bytes = loaded.bytes, .updated_at_ms = loaded.updated_at_ms, .modified_ns = loaded.modified_ns };
            },
            .v2 => {
                const bytes = (read.v2(self.alloc, home, session_id) catch |err| {
                    debug_trace.logf("usage", "usage recovery unreadable session={s} backend=v2 reason={s}", .{ session_id, @errorName(err) });
                    return null;
                }) orelse return null;
                self.held = bytes;
                return .{ .bytes = bytes, .updated_at_ms = 0 };
            },
        }
    }
};

/// A read-only profile for `fx usage`: never creates `~/.fx`, needs no
/// credentials.
pub const ReadOnly = struct {
    home: std.Io.Dir,
    recovery: Recovery,
    profile: usage_mod.Profile,

    pub fn open(self: *ReadOnly, alloc: Allocator, home_path: []const u8, readers: RecoveryReaders) !void {
        self.home = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home_path, .{ .iterate = true });
        errdefer self.home.close(io_mod.getIo());
        self.recovery = .{ .alloc = alloc, .home_path = try alloc.dupe(u8, home_path), .readers = readers };
        self.profile = usage_mod.Profile.init(alloc, io_mod.getIo(), .{
            .home = self.home,
            .mode = .read_only,
            .recovery = self.recovery.source(),
        });
    }

    pub fn deinit(self: *ReadOnly) void {
        self.profile.deinit();
        self.recovery.deinit();
        self.home.close(io_mod.getIo());
        self.* = undefined;
    }
};

/// A fresh ledger's snapshot after `added`/`removed` committed lines, for
/// tests that persist or decode one. The caller owns it.
pub fn testSnapshot(alloc: Allocator, added: u64, removed: u64) !usage_mod.Snapshot {
    if (comptime !builtin.is_test) @compileError("testSnapshot is for tests");
    const ledger = try usage_mod.Ledger.openDetached(alloc, std.testing.io, .{});
    defer ledger.close() catch {};
    if (added != 0 or removed != 0) {
        ledger.recordLines(added, removed);
        try ledger.flushActivity();
    }
    return ledger.snapshot(alloc);
}
