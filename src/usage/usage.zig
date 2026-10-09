//! The usage module's front door.
//!
//! - `Ledger`: one per session (TUI, `fx ask`, each ACP session). Restores the
//!   saved snapshot, records calls, and persists checkpoints through the
//!   host's `SessionSink`.
//! - `Call`: one model call, from `begin` to `finish`.
//! - `History`: usage history from AI Gateway's reports, the today, 7-day,
//!   and 30-day views; `ViewLoader` loads it off the UI thread.
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
const gateway_history = @import("gateway_history.zig");
const history_store = @import("io/history_store.zig");
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
    };
    pub const codec = struct {
        pub const record = @import("codec/record.zig");
        pub const snapshot = @import("codec/snapshot.zig");
    };
    pub const io = struct {
        pub const durable = @import("io/durable.zig");
        pub const worker = @import("io/worker.zig");
    };
};

/// The production Gateway origin.
pub const default_origin = "https://ai-gateway.vercel.sh";

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
    /// Null for a detached ledger that lives in memory only.
    sink: ?host.SessionSink,
    /// The Gateway origin lookup entries ask. Owned.
    origin: []u8,
    limits: core.Limits,
    /// The host gave a lookup transport. Without one, credentials only name
    /// the identity lookup entries are written with.
    can_look_up: bool,
    /// Written only under the worker's checkpoint lock.
    buffers: checkpoint.Buffers = .{},
    context_lock: Io.Mutex = .init,
    context: Context = .{},
    worker: worker.Worker,

    pub const Options = struct {
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

    /// Opens one session's ledger and starts what its saved snapshot owes.
    pub fn open(gpa: Allocator, io: Io, options: Options) !*Ledger {
        if (options.origin.len == 0 or options.origin.len > core.max_origin_bytes) return error.InvalidOrigin;
        const l = try gpa.create(Ledger);
        errdefer gpa.destroy(l);
        const origin = try gpa.dupe(u8, options.origin);
        errdefer gpa.free(origin);
        l.* = .{
            .gpa = gpa,
            .io = io,
            .sink = options.sink,
            .origin = origin,
            .limits = options.limits,
            .can_look_up = options.lookup != null,
            .worker = undefined,
        };
        try l.initWorker(options.saved, .{
            .limits = options.limits,
            .start = options.start,
            .lookup = options.lookup orelse l.noLookup(),
            .sink = .{ .context = l, .vtable = &Ledger.sink_vtable },
            .trace_instance = options.trace_instance,
            .schedule = options.schedule,
            .tracer = options.tracer,
            .wall_start = options.wall_start,
        });
        l.worker.start();
        return l;
    }

    /// A ledger that starts no task and looks nothing up. Exact calls settle
    /// into its totals at once; lookup entries wait. For single-threaded
    /// hosts, and for sessions that persist through no sink at all.
    pub fn openDetached(gpa: Allocator, io: Io, options: DetachedOptions) !*Ledger {
        const l = try gpa.create(Ledger);
        errdefer gpa.destroy(l);
        const origin = try gpa.dupe(u8, default_origin);
        errdefer gpa.free(origin);
        l.* = .{
            .gpa = gpa,
            .io = io,
            .sink = options.sink,
            .origin = origin,
            .limits = options.limits,
            .can_look_up = false,
            .worker = undefined,
        };
        try l.initWorker(options.saved, .{
            .limits = options.limits,
            .start = options.start,
            .lookup = l.noLookup(),
            .sink = .{ .context = l, .vtable = &Ledger.sink_vtable },
            .inline_only = true,
            .wall_start = options.wall_start,
        });
        return l;
    }

    fn initWorker(l: *Ledger, saved: ?Saved, options: worker.Options) !void {
        var parsed: ?Saved.Parsed = if (saved) |value| try value.parse(l.gpa) else null;
        defer if (parsed) |*value| value.deinit(l.gpa);
        const restore_buffers = try l.gpa.create(checkpoint.RestoreBuffers);
        defer l.gpa.destroy(restore_buffers);
        var with_restore = options;
        if (parsed) |*value| {
            const restored = try checkpoint.restoredOf(&value.snapshot, value.at_ms, restore_buffers);
            with_restore.restore = .{ .saved = restored, .saved_at_ms = value.at_ms };
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

    /// Joins the worker after a final checkpoint, then frees the ledger. The
    /// ledger is gone even when this fails.
    pub fn close(l: *Ledger) worker.CloseError!void {
        const result = l.worker.close();
        l.worker.deinit();
        const gpa = l.gpa;
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

    /// The session view. Usage history is `History`'s. The caller owns the
    /// result.
    pub fn view(l: *Ledger, gpa: Allocator, now_ms: i64, turn: TurnUsage) !View {
        var rows: [Limits.ceiling]core.ModelRow = undefined;
        const live = l.worker.view(&rows);
        var copy: core.Ledger = try .init(gpa, l.limits, .fresh);
        defer copy.deinit(gpa);
        l.worker.copyLedger(&copy);
        const buffers = try gpa.create(checkpoint.Buffers);
        defer gpa.destroy(buffers);
        const times: checkpoint.Times = .{ .at_ms = now_ms, .opened_at_ms = l.worker.openedAt() };
        const snap = checkpoint.snapshotOf(&copy, times, buffers);
        var session = try report.sessionViewFromSnapshot(gpa, &snap, now_ms, .fromLedger(live.unpriced), turn);
        const in_flight = copy.active.items.len;
        if (in_flight == 0) return session;
        // `completeness` keeps the checkpoint's reading, so ACP reports no
        // cost mid-call; the dashboard shows what the session settles to.
        var settled_times = times;
        settled_times.live = true;
        const settled = checkpoint.snapshotOf(&copy, settled_times, buffers);
        session.in_flight = std.math.cast(u32, in_flight) orelse std.math.maxInt(u32);
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
        const snap = checkpoint.snapshotOf(&copy, .{ .at_ms = wallMs(l.io), .opened_at_ms = l.worker.openedAt() }, buffers);
        return snapshot_codec.dupe(gpa, snap);
    }

    pub fn stats(l: *Ledger) Stats {
        return l.worker.stats();
    }

    fn step(l: *Ledger, event: worker.CallEvent) worker.ReportError!core.Transition {
        return l.worker.report(event);
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
        const snap = checkpoint.snapshotOf(frozen.ledger, .{ .at_ms = frozen.at_ms, .opened_at_ms = frozen.opened_at_ms }, &l.buffers);
        const saved: host.Checkpoint = .{ .number = frozen.number, .at_ms = frozen.at_ms, .snapshot = &snap };
        return sink.persist(&saved);
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

/// Length of a `gatewayUser` tag: `fx_` and 32 hex digits.
pub const gateway_user_len = 35;

/// The `providerOptions.gateway.user` tag for AI Gateway requests made with
/// this credential, written into `out`, so Gateway's usage reports can be
/// filtered to fx. It is `fx_` and the first 16 bytes of SHA-256 over a
/// domain prefix and the API key, in lowercase hex: one-way, the same on
/// every fx install using the key, and sent only to AI Gateway, which holds
/// the key already. Null for a credential with no stable key, such as a
/// sign-in or a deployment token.
pub fn gatewayUser(source: CredentialSource, secret: []const u8, out: *[gateway_user_len]u8) ?[]const u8 {
    switch (source) {
        .ai_gateway_api_key, .stored_key => {},
        .vercel_oidc_token,
        .fx_login,
        .chatgpt_subscription,
        .grok_subscription,
        .host_managed,
        .configured,
        => return null,
    }
    if (secret.len == 0) return null;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-gateway-user-v1\x00");
    hash.update(secret);
    const digest = hash.finalResult();
    out[0..3].* = "fx_".*;
    out[3..].* = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return out;
}

test "an API key's Gateway user tag is a stable one-way hash of the key" {
    const key = "vck_test_0000000000000000000000000000000000000000";
    var a: [gateway_user_len]u8 = undefined;
    var b: [gateway_user_len]u8 = undefined;
    const tag = gatewayUser(.stored_key, key, &a).?;
    try std.testing.expectEqualStrings("fx_83db22a6d365044adeb147e9ff055578", tag);
    // The same key tags the same user wherever fx read it from.
    try std.testing.expectEqualStrings(tag, gatewayUser(.ai_gateway_api_key, key, &b).?);
    try std.testing.expect(!std.mem.eql(u8, tag, gatewayUser(.stored_key, key ++ "1", &b).?));
    try std.testing.expectEqual(null, gatewayUser(.stored_key, "", &b));
    for ([_]CredentialSource{ .vercel_oidc_token, .fx_login, .chatgpt_subscription, .grok_subscription, .host_managed, .configured }) |source| {
        try std.testing.expectEqual(null, gatewayUser(source, key, &b));
    }
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
// History

/// Usage history from AI Gateway reports, for the dashboard and `fx usage`:
/// the stored snapshot, renewed through the host's transport when due.
/// Safe from any thread.
pub const History = struct {
    gpa: Allocator,
    io: Io,
    home: Io.Dir,
    lookup: ?host.Lookup,
    origin: []const u8,
    lock: Io.Mutex = .init,
    // Guarded by `lock`.
    held: Held = .{},
    failed_at_ms: ?i64 = null,

    const Held = struct {
        state: enum { needs_api_key, subscription, ready } = .needs_api_key,
        user: [gateway_user_len]u8 = undefined,
        secret: [host.Credential.max_secret_bytes]u8 = undefined,
        /// Null for host-managed auth: no bearer.
        secret_len: ?usize = null,
        team: [core.max_team_bytes]u8 = undefined,
        team_len: ?usize = null,

        fn wipe(held: *Held) void {
            std.crypto.secureZero(u8, &held.secret);
            held.* = .{};
        }

        fn same(a: *const Held, b: *const Held) bool {
            if (a.state != b.state) return false;
            if (a.state != .ready) return true;
            return std.mem.eql(u8, &a.user, &b.user) and
                optionalEql(a.secret[0 .. a.secret_len orelse 0], a.secret_len, b.secret[0 .. b.secret_len orelse 0], b.secret_len) and
                optionalEql(a.team[0 .. a.team_len orelse 0], a.team_len, b.team[0 .. b.team_len orelse 0], b.team_len);
        }

        fn optionalEql(a: []const u8, a_len: ?usize, b: []const u8, b_len: ?usize) bool {
            if ((a_len == null) != (b_len == null)) return false;
            return std.mem.eql(u8, a, b);
        }
    };

    pub const Options = struct {
        /// The directory that holds `.fx` (the user's HOME). Borrowed; open
        /// it with `.iterate = true`, since storing a snapshot syncs it and
        /// Linux can't sync a directory opened any other way (`O_PATH`).
        home: Io.Dir,
        /// fx's AI Gateway transport. Null shows only the stored snapshot.
        lookup: ?host.Lookup = null,
        /// Borrowed for the life of the history.
        origin: []const u8 = default_origin,
    };

    pub const Error = report.BuildError || error{Canceled};

    pub const Mode = enum {
        /// The stored snapshot only: no network.
        stored,
        /// Fetch new reports first when the snapshot is due.
        refresh_if_due,
        /// Fetch new reports first, as the user asked, unless a refresh
        /// ran in the last 30 seconds.
        refresh_now,
    };

    /// Does no I/O.
    pub fn init(gpa: Allocator, io: Io, options: Options) History {
        return .{ .gpa = gpa, .io = io, .home = options.home, .lookup = options.lookup, .origin = options.origin };
    }

    pub fn deinit(h: *History) void {
        h.held.wipe();
        h.* = undefined;
    }

    /// Whose history to show: an AI Gateway API key's fx user. Any other
    /// credential has no history, and the views say why. Copies the secret.
    /// The same credential again changes nothing, so a refresh that just
    /// failed still waits before fx tries again on its own.
    pub fn setCredential(h: *History, credential: Ledger.Credential) void {
        var next: Held = .{};
        defer next.wipe();
        hold(&next, credential);
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        if (h.held.same(&next)) return;
        h.held.wipe();
        h.held = next;
        h.failed_at_ms = null;
    }

    fn hold(held: *Held, credential: Ledger.Credential) void {
        const source = credential.source orelse return;
        switch (source) {
            .chatgpt_subscription, .grok_subscription => held.state = .subscription,
            .ai_gateway_api_key, .stored_key => {
                const secret = switch (credential.credential) {
                    .bearer => |value| value,
                    .signed_out, .host_managed => return,
                };
                if (secret.len > host.Credential.max_secret_bytes) return;
                if (credential.team) |team| {
                    if (team.len > core.max_team_bytes) return;
                    @memcpy(held.team[0..team.len], team);
                    held.team_len = team.len;
                }
                _ = gatewayUser(source, secret, &held.user) orelse return;
                @memcpy(held.secret[0..secret.len], secret);
                held.secret_len = secret.len;
                held.state = .ready;
            },
            .vercel_oidc_token, .fx_login, .host_managed, .configured => {},
        }
    }

    /// The three history views at `now_ms`, in `Scope.rolling` order, or
    /// null in `stored` mode when nothing is stored yet. Blocks while a
    /// refresh runs, which `cancel` stops. The caller owns the views.
    pub fn views(h: *History, gpa: Allocator, now_ms: i64, mode: Mode, cancel: *const std.atomic.Value(bool)) Error!?[Scope.rolling.len]View {
        // A copy, so the lock is never held across the network.
        var held: Held = undefined;
        const failed_at_ms = blk: {
            h.lock.lockUncancelable(h.io);
            defer h.lock.unlock(h.io);
            held = h.held;
            break :blk h.failed_at_ms;
        };
        defer std.crypto.secureZero(u8, &held.secret);
        switch (held.state) {
            .needs_api_key => return try unavailableViews(gpa, now_ms, .needs_api_key),
            .subscription => return try unavailableViews(gpa, now_ms, .subscription),
            .ready => {},
        }
        const user: []const u8 = &held.user;
        const team = if (held.team_len) |len| held.team[0..len] else null;

        var arena_state = std.heap.ArenaAllocator.init(h.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var stored = history_store.read(h.io, h.home, arena, gateway_history.identityOf(user, team));
        // Until a refresh succeeds, the last one's failure stands.
        var refresh_failed = failed_at_ms != null;
        const due = mode != .stored and h.lookup != null and gateway_history.refreshDue(.{
            .snapshot = if (stored) |*value| value else null,
            .failed_at_ms = failed_at_ms,
        }, now_ms, mode == .refresh_now);
        if (due) {
            const body = try arena.alloc(u8, history_store.max_body_bytes);
            const credential: history_store.Credential = .{
                .secret = if (held.secret_len) |len| held.secret[0..len] else null,
                .team = team,
                .user = user,
            };
            switch (history_store.fetch(arena, h.lookup.?, h.origin, credential, now_ms, cancel, body)) {
                .fetched, .refused => |fresh| {
                    // A snapshot that fails to save still shows; the next
                    // refresh writes again.
                    history_store.write(h.io, h.home, h.gpa, fresh) catch {};
                    stored = fresh;
                    refresh_failed = false;
                    h.setFailedAt(null);
                },
                .failed => {
                    refresh_failed = true;
                    h.setFailedAt(now_ms);
                },
                .canceled => return error.Canceled,
            }
        }
        const latest = stored orelse {
            if (mode == .stored) return null;
            return try unavailableViews(gpa, now_ms, .failed);
        };
        if (latest.refused) return try unavailableViews(gpa, now_ms, .refused);
        return try historyViews(gpa, latest, refresh_failed);
    }

    fn setFailedAt(h: *History, at_ms: ?i64) void {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        h.failed_at_ms = at_ms;
    }

    fn periodOf(scope: Scope) gateway_history.Period {
        return switch (scope) {
            .today => .today,
            .days_7 => .days_7,
            .days_30 => .days_30,
            .session => unreachable,
        };
    }

    fn historyViews(gpa: Allocator, latest: gateway_history.Snapshot, refresh_failed: bool) report.BuildError![Scope.rolling.len]View {
        var out: [Scope.rolling.len]View = undefined;
        var built: usize = 0;
        errdefer for (out[0..built]) |*one| one.deinit(gpa);
        for (Scope.rolling, &out) |scope, *dst| {
            const period = periodOf(scope);
            dst.* = try report.historyView(
                gpa,
                scope,
                latest.periods[@intFromEnum(period)],
                latest.fetched_at_ms,
                gateway_history.firstDay(period, latest.today),
                refresh_failed,
            );
            built += 1;
        }
        return out;
    }

    fn unavailableViews(gpa: Allocator, now_ms: i64, reason: report.Unavailable) Allocator.Error![Scope.rolling.len]View {
        var out: [Scope.rolling.len]View = undefined;
        var built: usize = 0;
        errdefer for (out[0..built]) |*one| one.deinit(gpa);
        for (Scope.rolling, &out) |scope, *dst| {
            dst.* = try report.unavailableView(gpa, scope, now_ms, reason);
            built += 1;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Dashboard views

/// Builds the three history views off the owner's thread, for the TUI
/// dashboard: first from the stored snapshot, then again after a refresh
/// when one is due. `refresh`, `poll`, `view`, and `deinit` are called from
/// one thread; the load runs as a task when the host can run one, else
/// inline.
pub const ViewLoader = struct {
    history: *History,
    gpa: Allocator,
    lock: Io.Mutex = .init,
    task: ?Io.Future(void) = null,
    /// Set by `deinit` to stop a refresh in progress.
    cancel: std.atomic.Value(bool) = .init(false),
    // Guarded by `lock`.
    loading: bool = false,
    finished: ?Result = null,
    // Owner thread only.
    current: ?[Scope.rolling.len]View = null,
    /// The views `poll` replaced, kept until the next `poll` so the owner
    /// can carry its selection over.
    retired: ?[Scope.rolling.len]View = null,
    last_error: ?ViewsError = null,

    pub const ViewsError = History.Error;

    const Result = union(enum) {
        ready: [Scope.rolling.len]View,
        failed: ViewsError,
    };

    pub const Transition = enum { none, ready, failed };

    pub fn init(history: *History, gpa: Allocator) ViewLoader {
        return .{ .history = history, .gpa = gpa };
    }

    /// Stops a refresh in progress, waits for the load, then frees every
    /// view.
    pub fn deinit(v: *ViewLoader) void {
        v.cancel.store(true, .release);
        if (v.task) |*task| task.await(v.history.io);
        if (v.finished) |*result| v.freeResult(result);
        if (v.current) |*views| v.freeViews(views);
        if (v.retired) |*views| v.freeViews(views);
        v.* = undefined;
    }

    /// Starts loading the views at `now_ms` unless a load is running.
    /// `asked` is a refresh the user asked for. Returns whether it started.
    pub fn refresh(v: *ViewLoader, now_ms: i64, asked: bool) bool {
        {
            v.lock.lockUncancelable(v.history.io);
            defer v.lock.unlock(v.history.io);
            if (v.loading) return false;
            v.loading = true;
        }
        // The last load cleared `loading` as its final step.
        if (v.task) |*done| done.await(v.history.io);
        v.task = v.history.io.concurrent(load, .{ v, now_ms, asked }) catch blk: {
            load(v, now_ms, asked);
            break :blk null;
        };
        return true;
    }

    fn load(v: *ViewLoader, now_ms: i64, asked: bool) void {
        // The stored snapshot first, so the dashboard never waits on the
        // network.
        if (v.history.views(v.gpa, now_ms, .stored, &v.cancel)) |stored| {
            if (stored) |views| v.publish(.{ .ready = views }, false);
        } else |err| {
            v.publish(.{ .failed = err }, false);
        }
        const mode: History.Mode = if (asked) .refresh_now else .refresh_if_due;
        const result: ?Result = if (v.history.views(v.gpa, now_ms, mode, &v.cancel)) |views|
            (if (views) |ready| .{ .ready = ready } else null)
        else |err| switch (err) {
            error.Canceled => null,
            else => .{ .failed = err },
        };
        if (result) |value| v.publish(value, true) else v.finish();
    }

    fn publish(v: *ViewLoader, result: Result, last: bool) void {
        v.lock.lockUncancelable(v.history.io);
        defer v.lock.unlock(v.history.io);
        if (v.finished) |*old| v.freeResult(old);
        v.finished = result;
        if (last) v.loading = false;
    }

    fn finish(v: *ViewLoader) void {
        v.lock.lockUncancelable(v.history.io);
        defer v.lock.unlock(v.history.io);
        v.loading = false;
    }

    /// Whether a load is running.
    pub fn isLoading(v: *ViewLoader) bool {
        v.lock.lockUncancelable(v.history.io);
        defer v.lock.unlock(v.history.io);
        return v.loading;
    }

    /// What finished since the last poll. After `.ready`, `view` returns the
    /// new views, and the ones they replaced stay valid until the next poll.
    /// After `.failed`, the old views stay and `lastError` says why.
    pub fn poll(v: *ViewLoader) Transition {
        const result = blk: {
            v.lock.lockUncancelable(v.history.io);
            defer v.lock.unlock(v.history.io);
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

    /// The loaded view of a history scope, or null. Borrowed until the poll
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
    _ = @import("gateway_history.zig");
    _ = @import("core/ledger.zig");
    _ = @import("host.zig");
    _ = @import("io/durable.zig");
    _ = @import("io/history_store.zig");
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

test "an exact receipt settles once, and the session restores with it" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};

    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        call.gatewayEvent(test_finish);
        const finished = try call.finish(.completed);
        try testing.expectEqual(core.State.settled, finished.to);
    }
    try ledger.close();

    // The checkpoint holds the settled totals and owes nothing.
    var saved = try snapshot.parseSidecar(testing.allocator, sink.bytes.?);
    defer saved.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.0123), saved.snapshot.total_cost);
    try testing.expectEqual(@as(usize, 0), saved.snapshot.publication_backlog.len);
    try testing.expectEqual(@as(usize, 0), saved.snapshot.pending.len);

    // Reopened from the sidecar, the session view shows the same call, once.
    const now = wallMs(testing.io);
    const again = try Ledger.open(testing.allocator, testing.io, .{
        .saved = .{ .sidecar = .{ .bytes = sink.bytes.?, .updated_at_ms = sink.at_ms } },
        .sink = sink.handle(),
        .lookup = lookup.handle(),
    });
    {
        errdefer again.close() catch {};
        var session = try again.view(testing.allocator, now + 1, .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 0.0123), session.totals.?.total_cost);
        try testing.expectEqual(report.Completeness.complete, session.completeness);
    }
    try again.close();
}

test "a cancelled call with an id waits for a lookup, and its checkpoint keeps it" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};

    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer ledger.close() catch {};
        var call = try ledger.begin(.gateway);
        call.gatewayEvent(test_id_event);
        const finished = try call.finish(.cancelled);
        try testing.expectEqual(core.State.lookup, finished.to);
        var session = try ledger.view(testing.allocator, wallMs(testing.io), .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(report.Completeness.pending, session.completeness);
        // Signed out is waiting, not blocked (only a 401/403 blocks).
        try testing.expectEqual(@as(?core.UnpricedReason, .lookup_pending), session.unpriced.reason);
    }
    try ledger.close();
    // Signed out, so nothing was looked up, and the next run still can.
    try testing.expectEqual(@as(u32, 0), lookup.fetches.load(.monotonic));
    var saved = try snapshot.parseSidecar(testing.allocator, sink.bytes.?);
    defer saved.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), saved.snapshot.pending.len);
}

test "an origin the ledger can't keep is refused" {
    var sink: TestSink = .{};
    defer sink.deinit();
    try testing.expectError(error.InvalidOrigin, Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle(), .origin = "" }));
}

test "a reopened session looks its waiting entries up once a credential arrives" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var sink: TestSink = .{};
    defer sink.deinit();
    var lookup: TestLookup = .{};
    const first = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle(), .lookup = lookup.handle() });
    {
        errdefer first.close() catch {};
        var call = try first.begin(.gateway);
        call.gatewayEvent(test_id_event);
        try testing.expectEqual(core.State.lookup, (try call.finish(.completed)).to);
    }
    try first.close();
    try testing.expectEqual(@as(u32, 0), lookup.fetches.load(.monotonic));

    const again = try Ledger.open(testing.allocator, testing.io, .{
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
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle() });
    defer ledger.close() catch {};
    try ledger.setCredential(.{ .credential = .{ .bearer = "vck_key" }, .source = .ai_gateway_api_key });
    var call = try ledger.begin(.gateway);
    call.gatewayEvent(test_id_event);
    _ = try call.finish(.completed);
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(u32, 0), ledger.stats().lookups);
    var session = try ledger.view(testing.allocator, wallMs(testing.io), .{});
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
    var sink: Failing = .{ .fail_at = 1 };
    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle() });
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
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle() });
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
        try testing.expectEqual(core.State.settled, finished.to);
        var session = try ledger.view(testing.allocator, wallMs(testing.io), .{});
        defer session.deinit(testing.allocator);
        try testing.expectEqual(report.Completeness.complete, session.completeness);
        try testing.expectEqual(@as(f64, 0.0123), session.totals.?.total_cost);
        try testing.expectEqual(@as(?u64, 155), ledger.liveContext());
        try testing.expectEqual(@as(u32, 0), ledger.stats().spawns);

        // A copy restored from its snapshot shows the same totals.
        var saved = try ledger.snapshot(testing.allocator);
        defer saved.deinit(testing.allocator);
        try testing.expectEqual(snapshot.Billing.complete, saved.billing);
        const again = try Ledger.openDetached(testing.allocator, testing.io, .{ .saved = .{ .parsed = .{ .snapshot = &saved, .at_ms = wallMs(testing.io) } } });
        defer again.close() catch {};
        var restored = try again.view(testing.allocator, wallMs(testing.io), .{});
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
    var during = try ledger.view(testing.allocator, wallMs(testing.io), .{});
    defer during.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, during.completeness);
    try testing.expectEqual(@as(?f64, null), report.completeCost(&during));
    try testing.expectEqual(@as(u32, 1), during.in_flight);
    try testing.expectEqual(report.Completeness.complete, during.settled_completeness);
    try testing.expect(during.session_activity.?.api_duration_complete);
    try testing.expectEqual(@as(f64, 0.0123), during.totals.?.total_cost);

    _ = try open.finish(.failed_unbilled);
    var after = try ledger.view(testing.allocator, wallMs(testing.io), .{});
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
    try testing.expectEqual(core.State.settled, (try call.finish(.completed)).to);
}

test "a subscription id the ledger refuses still ends the call" {
    const ledger = try Ledger.openDetached(testing.allocator, testing.io, .{});
    defer ledger.close() catch {};
    var call = try ledger.begin(.codex);
    try testing.expectEqual(core.State.unpriced, (try call.finishExact(.{ .external_id = "", .model = "openai/gpt-5" })).to);
    var ok = try ledger.begin(.codex);
    try testing.expectEqual(core.State.settled, (try ok.finishExact(.{ .external_id = "resp_1", .model = "openai/gpt-5", .input_tokens = 3 })).to);
    var session = try ledger.view(testing.allocator, wallMs(testing.io), .{});
    defer session.deinit(testing.allocator);
    try testing.expectEqual(report.Completeness.incomplete, session.completeness);
    try testing.expectEqual(@as(u64, 3), session.totals.?.input_tokens);
}

test "lines are durable at flushActivity, and code completeness can be lost" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var sink: TestSink = .{};
    defer sink.deinit();
    const ledger = try Ledger.open(testing.allocator, testing.io, .{ .sink = sink.handle() });
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

/// A fake AI Gateway for history tests: answers in order, or holds until
/// the request is canceled.
const FakeReports = struct {
    answers: []const Answer,
    used: std.atomic.Value(usize) = .init(0),

    const Answer = union(enum) { body: []const u8, status: u16, hold };

    fn lookup(f: *FakeReports) host.Lookup {
        return .{ .context = f, .vtable = &.{ .trusted = trusted, .fetch = fetch } };
    }

    fn trusted(_: *anyopaque, _: []const u8) bool {
        return true;
    }

    fn fetch(context: *anyopaque, request: *const host.Lookup.Request, body: []u8) host.Lookup.FetchError!host.Lookup.Response {
        const f: *FakeReports = @ptrCast(@alignCast(context));
        const index = f.used.fetchAdd(1, .acq_rel);
        const answer = if (index < f.answers.len) f.answers[index] else Answer{ .status = 500 };
        switch (answer) {
            .status => |status| return .{ .status = status, .body_len = 0 },
            .body => |text| {
                @memcpy(body[0..text.len], text);
                return .{ .status = 200, .body_len = text.len };
            },
            .hold => {
                while (!request.cancel.load(.acquire)) {
                    testing.io.sleep(.fromMilliseconds(1), .awake) catch return error.Canceled;
                }
                return error.Canceled;
            },
        }
    }
};

const history_report =
    \\{"results":[{"model":"openai/gpt-4.1-nano","total_cost":0.5,"input_tokens":100,"output_tokens":10,"cached_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_tokens":0,"request_count":2}]}
;
const history_key: Ledger.Credential = .{ .credential = .{ .bearer = "vck_history_test" }, .source = .stored_key };

fn freeHistoryViews(views: *[Scope.rolling.len]View) void {
    for (views) |*one| one.deinit(testing.allocator);
}

test "history views say why a credential has none" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fake: FakeReports = .{ .answers = &.{} };
    var history: History = .init(testing.allocator, testing.io, .{ .home = tmp.dir, .lookup = fake.lookup() });
    defer history.deinit();
    var never: std.atomic.Value(bool) = .init(false);
    const cases = [_]struct { credential: Ledger.Credential, want: report.Unavailable }{
        .{ .credential = .{ .credential = .signed_out }, .want = .needs_api_key },
        .{ .credential = .{ .credential = .{ .bearer = "token" }, .source = .fx_login }, .want = .needs_api_key },
        .{ .credential = .{ .credential = .{ .bearer = "token" }, .source = .vercel_oidc_token }, .want = .needs_api_key },
        .{ .credential = .{ .credential = .host_managed, .source = .host_managed }, .want = .needs_api_key },
        .{ .credential = .{ .credential = .signed_out, .source = .stored_key }, .want = .needs_api_key },
        .{ .credential = .{ .credential = .signed_out, .source = .chatgpt_subscription }, .want = .subscription },
        .{ .credential = .{ .credential = .signed_out, .source = .grok_subscription }, .want = .subscription },
    };
    for (cases) |case| {
        history.setCredential(case.credential);
        var views = (try history.views(testing.allocator, 0, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        for (views) |one| {
            try testing.expectEqual(case.want, one.history.?.unavailable.?);
            try testing.expect(one.totals == null);
        }
    }
    try testing.expectEqual(@as(usize, 0), fake.used.load(.acquire));
}

test "history reads its snapshot, refreshes when due, and keeps it when a refresh fails" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fake: FakeReports = .{ .answers = &.{
        .{ .body = history_report },
        .{ .body = history_report },
        .{ .body = history_report },
        .{ .status = 503 },
        .{ .status = 403 },
    } };
    var history: History = .init(testing.allocator, testing.io, .{ .home = tmp.dir, .lookup = fake.lookup() });
    defer history.deinit();
    history.setCredential(history_key);
    var never: std.atomic.Value(bool) = .init(false);
    // 2026-10-09 05:00 UTC.
    const now: i64 = 1_791_504_000_000 + 5 * std.time.ms_per_hour;

    try testing.expectEqual(null, try history.views(testing.allocator, now, .stored, &never));
    {
        var views = (try history.views(testing.allocator, now, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 3), fake.used.load(.acquire));
        for (views) |one| {
            try testing.expectEqual(now, one.history.?.as_of_ms.?);
            try testing.expect(!one.history.?.refresh_failed);
            try testing.expectEqual(@as(f64, 0.5), one.totals.?.total_cost);
            try testing.expectEqual(@as(?u64, 2), one.totals.?.request_count);
            try testing.expectEqualStrings("openai/gpt-4.1-nano", one.models[0].model);
        }
        try testing.expectEqual(Scope.days_30, views[0].scope);
        // 30 whole UTC days: 2026-09-10 00:00 UTC on.
        try testing.expectEqual(@as(i64, 1_788_998_400_000), views[0].window_start_ms);
    }
    // Stored, and not due a minute later: no fetch.
    {
        var views = (try history.views(testing.allocator, now + std.time.ms_per_min, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 3), fake.used.load(.acquire));
        try testing.expectEqual(now, views[2].history.?.as_of_ms.?);
    }
    // Stale: the refresh fails, and the snapshot stays, marked.
    const later = now + gateway_history.stale_after_ms;
    {
        var views = (try history.views(testing.allocator, later, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 4), fake.used.load(.acquire));
        try testing.expect(views[0].history.?.refresh_failed);
        try testing.expectEqual(now, views[0].history.?.as_of_ms.?);
    }
    // fx waits a minute before trying on its own, and still says it failed,
    // even when a call sets the same key again.
    history.setCredential(history_key);
    {
        var views = (try history.views(testing.allocator, later + 1000, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 4), fake.used.load(.acquire));
        try testing.expect(views[0].history.?.refresh_failed);
    }
    // Asked after 30 s: AI Gateway refuses the key, and that is remembered.
    {
        var views = (try history.views(testing.allocator, later + 31 * std.time.ms_per_s, .refresh_now, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 5), fake.used.load(.acquire));
        try testing.expectEqual(report.Unavailable.refused, views[1].history.?.unavailable.?);
    }
    {
        var views = (try history.views(testing.allocator, later + std.time.ms_per_hour, .refresh_if_due, &never)).?;
        defer freeHistoryViews(&views);
        try testing.expectEqual(@as(usize, 5), fake.used.load(.acquire));
        try testing.expectEqual(report.Unavailable.refused, views[1].history.?.unavailable.?);
    }
    // Another key has no snapshot of its own.
    history.setCredential(.{ .credential = .{ .bearer = "vck_other" }, .source = .ai_gateway_api_key });
    try testing.expectEqual(null, try history.views(testing.allocator, later, .stored, &never));
}

test "the view loader shows the stored snapshot first and cancels a refresh on close" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fake: FakeReports = .{ .answers = &.{ .{ .body = history_report }, .{ .body = history_report }, .{ .body = history_report }, .hold } };
    var history: History = .init(testing.allocator, testing.io, .{ .home = tmp.dir, .lookup = fake.lookup() });
    defer history.deinit();
    history.setCredential(history_key);
    const now = wallMs(testing.io);
    {
        var loader: ViewLoader = .init(&history, testing.allocator);
        defer loader.deinit();
        try testing.expectEqual(ViewLoader.Transition.none, loader.poll());
        try testing.expect(loader.refresh(now, false));
        while (loader.isLoading()) try testing.io.sleep(.fromMilliseconds(1), .awake);
        try testing.expectEqual(ViewLoader.Transition.ready, loader.poll());
        try testing.expectEqual(@as(f64, 0.5), loader.view(.today).?.totals.?.total_cost);
        try testing.expect(loader.view(.session) == null);
    }
    // Asked again: the stored views arrive while the refresh hangs, and
    // closing the loader stops it.
    var loader: ViewLoader = .init(&history, testing.allocator);
    try testing.expect(loader.refresh(now + 31 * std.time.ms_per_s, true));
    var ready = false;
    for (0..5000) |_| {
        if (loader.poll() == .ready) {
            ready = true;
            break;
        }
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(ready);
    try testing.expectEqual(now, loader.view(.days_7).?.history.?.as_of_ms.?);
    for (0..5000) |_| {
        if (fake.used.load(.acquire) >= 4) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 4), fake.used.load(.acquire));
    try testing.expect(loader.isLoading());
    loader.deinit();
    try testing.expectEqual(@as(usize, 4), fake.used.load(.acquire));
}
