//! Reports: the one `View` every usage surface draws, built from parsed
//! profile ledger records, recovered session state, and the session ledger.
//!
//! The rules are the ones older fx binaries used, so every surface shows the
//! same numbers: scopes and their tab order, UTC dates, window bounds,
//! totals arithmetic, model order and caps, the merge of the profile ledger
//! with what marked sessions still owe it, the read rules for `usage.jsonl`
//! (two variants per id, pending-conflict incidents, one coverage line), the
//! 4096-entry recovery bounds, a session's start (now minus wall time), and
//! a live cost only when complete.
//!
//! New and not in any existing output: `View.unpriced`, the calls missing
//! from the totals and why. Rolling views
//! count unresolved pending markers in the window (`lookup_pending`, or
//! `sign_in_cannot_look_up` for ids the caller reports blocked) and
//! `incomplete` incidents in the window (`no_receipt`). Session views take
//! the ledger core's count unchanged.
//!
//! Pure: no I/O, no clock. Views own their model names; free with `deinit`.

const std = @import("std");
const record = @import("codec/record.zig");
const snapshot_codec = @import("codec/snapshot.zig");
const ledger_core = @import("core/ledger.zig");

const Allocator = std.mem.Allocator;

pub const GenerationFact = record.GenerationFact;
pub const PendingMarker = record.PendingMarker;
pub const Incident = record.Incident;
pub const UnpricedReason = ledger_core.UnpricedReason;

/// Most model rows one view holds (`usage_report.max_models`).
pub const max_models: usize = 128;
/// Longest model name a session source may carry.
pub const max_model_bytes: usize = record.max_model_bytes;
/// Largest `usage.jsonl` a reader accepts (`profile_usage_store.max_file_bytes`).
pub const max_file_bytes: usize = 32 * 1024 * 1024;
/// Recovery bounds (`usage_recovery.max_recovery_*`). Overflow is unknown pending.
pub const max_recovery_facts: usize = 4096;
pub const max_recovery_incidents: usize = 4096;
pub const max_recovery_pending: usize = 4096;

// ---------------------------------------------------------------------------
// Scopes

pub const Scope = enum {
    session,
    hours_24,
    days_7,
    days_30,

    /// Rolling scopes in the order the dashboard loads them.
    pub const rolling = [_]Scope{ .days_30, .days_7, .hours_24 };
    /// Dashboard period order, left to right: the session first, since the
    /// dashboard opens on it.
    pub const tab_order = [_]Scope{ .session, .hours_24, .days_7, .days_30 };

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .session => "Session",
            .hours_24 => "24 hours",
            .days_7 => "7 days",
            .days_30 => "30 days",
        };
    }

    /// The `--period` value, or null for the session.
    pub fn cliValue(self: Scope) ?[]const u8 {
        return switch (self) {
            .session => null,
            .hours_24 => "24h",
            .days_7 => "7d",
            .days_30 => "30d",
        };
    }

    /// Parses a `--period` value. `session` is not a period.
    pub fn fromCliValue(text: []const u8) ?Scope {
        inline for (.{ Scope.hours_24, Scope.days_7, Scope.days_30 }) |scope| {
            if (std.mem.eql(u8, text, scope.cliValue().?)) return scope;
        }
        return null;
    }

    /// Window length, or null for the session.
    pub fn durationMs(self: Scope) ?i64 {
        return switch (self) {
            .session => null,
            .hours_24 => std.time.ms_per_hour * 24,
            .days_7 => std.time.ms_per_day * 7,
            .days_30 => std.time.ms_per_day * 30,
        };
    }

    /// The Left key. Periods read session 24h 7d 30d left to right, so Left
    /// moves toward the session, without wrapping.
    pub fn previous(self: Scope) Scope {
        return switch (self) {
            .session => .session,
            .hours_24 => .session,
            .days_7 => .hours_24,
            .days_30 => .days_7,
        };
    }

    /// The Right key: toward 30 days, without wrapping. Tab moves the same
    /// way and wraps.
    pub fn next(self: Scope) Scope {
        return switch (self) {
            .session => .hours_24,
            .hours_24 => .days_7,
            .days_7 => .days_30,
            .days_30 => .days_30,
        };
    }

    pub const Direction = enum { forward, backward };

    /// Tab (`forward`) and Shift+Tab (`backward`), wrapping:
    /// session → 24h → 7d → 30d → session.
    pub fn cycle(self: Scope, direction: Direction) Scope {
        return switch (direction) {
            .forward => switch (self) {
                .session => .hours_24,
                .hours_24 => .days_7,
                .days_7 => .days_30,
                .days_30 => .session,
            },
            .backward => switch (self) {
                .session => .days_30,
                .hours_24 => .session,
                .days_7 => .hours_24,
                .days_30 => .days_7,
            },
        };
    }
};

/// `Oct 7, 2026` in UTC, or `Unknown` before the epoch.
pub fn formatUtcDate(buf: *[24]u8, timestamp_ms: i64) []const u8 {
    if (timestamp_ms < 0) return "Unknown";
    const seconds: u64 = @intCast(@divFloor(timestamp_ms, std.time.ms_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month = months[month_day.month.numeric() - 1];
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ month, month_day.day_index + 1, year_day.year }) catch "Unknown";
}

// ---------------------------------------------------------------------------
// The view

pub const Completeness = enum { complete, pending, incomplete, legacy };

pub const Coverage = enum { not_started, partial, full };

pub const Totals = struct {
    total_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    request_count: ?u64,
    total_cost: f64,
};

pub const ModelUsage = struct {
    model: []const u8,
    totals: Totals,
};

pub const SessionActivity = struct {
    api_duration_complete: bool,
    wall_duration_complete: bool,
    code_complete: bool,
    api_duration_ms: u64,
    wall_duration_ms: u64,
    lines_added: u64,
    lines_removed: u64,
};

/// Calls missing from the totals, and the most actionable reason.
pub const Unpriced = struct {
    count: u64 = 0,
    /// Null when `count` is 0. A sign-in that cannot look up cost first, then
    /// lookups still running, then calls with no receipt (the ledger core's
    /// order).
    reason: ?UnpricedReason = null,
    lookup_pending: u64 = 0,
    sign_in_cannot_look_up: u64 = 0,
    no_receipt: u64 = 0,

    pub const none: Unpriced = .{};

    pub fn fromCounts(lookup_pending: u64, sign_in_cannot_look_up: u64, no_receipt: u64) Unpriced {
        return .{
            .count = lookup_pending +| sign_in_cannot_look_up +| no_receipt,
            .reason = if (sign_in_cannot_look_up > 0)
                .sign_in_cannot_look_up
            else if (lookup_pending > 0)
                .lookup_pending
            else if (no_receipt > 0)
                .no_receipt
            else
                null,
            .lookup_pending = lookup_pending,
            .sign_in_cannot_look_up = sign_in_cannot_look_up,
            .no_receipt = no_receipt,
        };
    }

    /// The session ledger core's count, unchanged.
    pub fn fromLedger(value: ledger_core.Unpriced) Unpriced {
        return fromCounts(value.lookup_pending, value.sign_in_cannot_look_up, value.no_receipt);
    }
};

/// Main-agent token sums for the current turn (`Agent.turn_usage`). Null
/// means no completion reported that count.
pub const TurnUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,

    /// Adds one completion's counts. Saturates like `Agent.observeUsage`.
    pub fn add(self: *TurnUsage, usage: TurnUsage) void {
        inline for (std.meta.fields(TurnUsage)) |field| {
            if (@field(usage, field.name)) |amount| {
                @field(self, field.name) = (@field(self, field.name) orelse 0) +| amount;
            }
        }
    }
};

/// What every surface draws for one scope. Owns `models` and their names;
/// free with `deinit`.
pub const View = struct {
    scope: Scope,
    snapshot_time_ms: i64,
    /// Rolling: `snapshot_time_ms` minus the window. Session: its start.
    window_start_ms: i64,
    coverage_started_at_ms: ?i64,
    coverage: Coverage,
    completeness: Completeness,
    /// Null when tracking has not started, or for a legacy session.
    totals: ?Totals,
    /// At most `max_models`, by total tokens, then cost, both descending,
    /// then name.
    models: []ModelUsage,
    session_activity: ?SessionActivity = null,
    unpriced: Unpriced = .none,
    /// Session views only.
    turn: ?TurnUsage = null,
    /// Session views only: calls started and not yet finished. Their cost
    /// is not in the totals, so `completeness` reads incomplete while any
    /// are open, as a saved checkpoint does.
    in_flight: u32 = 0,
    /// What `completeness` reads once those calls finish. Meaningful only
    /// when `in_flight > 0`.
    settled_completeness: Completeness = .complete,

    pub fn deinit(self: *View, alloc: Allocator) void {
        for (self.models) |model| alloc.free(model.model);
        alloc.free(self.models);
        self.* = undefined;
    }
};

pub const BuildError = Allocator.Error || error{
    InvalidGenerationFact,
    InvalidSnapshotTime,
    UsageCapacityExceeded,
    UsageOverflow,
};

// ---------------------------------------------------------------------------
// Profile ledger read rules

pub const LoadError = Allocator.Error || error{
    InvalidUsageStore,
    UsageStoreIncomplete,
    UsageCapacityExceeded,
};

/// Borrowed contents of one parsed `usage.jsonl` (fx's `Loaded`).
pub const LedgerContents = struct {
    coverage_started_at_ms: ?i64 = null,
    facts: []const GenerationFact = &.{},
    pending: []const PendingMarker = &.{},
    incidents: []const Incident = &.{},
};

/// The parsed profile ledger, with fx's reader rules. Owns every string;
/// free with `deinit`.
pub const ProfileLedger = struct {
    coverage_started_at_ms: ?i64 = null,
    facts: std.ArrayList(GenerationFact) = .empty,
    pending: std.ArrayList(PendingMarker) = .empty,
    incidents: std.ArrayList(Incident) = .empty,
    record_count: usize = 0,
    fact_variants: std.StringHashMapUnmanaged(Variants) = .empty,
    pending_variants: std.StringHashMapUnmanaged(Variants) = .empty,

    const Variants = struct { first: usize, second: ?usize = null };

    pub fn deinit(self: *ProfileLedger, alloc: Allocator) void {
        self.fact_variants.deinit(alloc);
        self.pending_variants.deinit(alloc);
        for (self.facts.items) |*fact| fact.deinit(alloc);
        self.facts.deinit(alloc);
        for (self.pending.items) |*marker| marker.deinit(alloc);
        self.pending.deinit(alloc);
        self.incidents.deinit(alloc);
        self.* = undefined;
    }

    pub fn contents(self: *const ProfileLedger) LedgerContents {
        return .{
            .coverage_started_at_ms = self.coverage_started_at_ms,
            .facts = self.facts.items,
            .pending = self.pending.items,
            .incidents = self.incidents.items,
        };
    }

    /// Parses a whole `usage.jsonl` read (`loadFromFile`): at most 32 MiB,
    /// empty is an empty ledger, and a torn tail (no final newline) is
    /// `UsageStoreIncomplete`, since readers never repair. The caller owns
    /// the result. `bytes` is borrowed.
    pub fn load(alloc: Allocator, bytes: []const u8) LoadError!ProfileLedger {
        if (bytes.len > max_file_bytes) return error.UsageCapacityExceeded;
        var ledger: ProfileLedger = .{};
        errdefer ledger.deinit(alloc);
        if (bytes.len == 0) return ledger;
        if (bytes[bytes.len - 1] != '\n') return error.UsageStoreIncomplete;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            ledger.record_count += 1;
            if (ledger.record_count > record.max_records or line.len > record.max_record_bytes) {
                return error.UsageCapacityExceeded;
            }
            var parsed = record.parseRecord(alloc, line) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUsageStore => return error.InvalidUsageStore,
            };
            defer parsed.deinit(alloc);
            try ledger.absorb(alloc, parsed);
        }
        return ledger;
    }

    /// Adds one parsed record (`absorbRecord`). Copies what it keeps.
    /// - One coverage value per file; a different second one is invalid.
    /// - Generation and pending records need a coverage line before them.
    /// - Each id keeps at most two distinct variants; an exact repeat is
    ///   dropped. A second pending variant adds an `incomplete` incident at
    ///   its `observed_at_ms`.
    pub fn absorb(self: *ProfileLedger, alloc: Allocator, parsed: record.Record) (Allocator.Error || error{InvalidUsageStore})!void {
        switch (parsed) {
            .coverage => |started_at_ms| {
                if (self.coverage_started_at_ms) |existing| {
                    if (existing != started_at_ms) return error.InvalidUsageStore;
                } else {
                    self.coverage_started_at_ms = started_at_ms;
                }
            },
            .generation => |fact| {
                if (self.coverage_started_at_ms == null) return error.InvalidUsageStore;
                const existing = self.fact_variants.getPtr(fact.id);
                if (existing) |variants| {
                    if (GenerationFact.eql(self.facts.items[variants.first], fact)) return;
                    if (variants.second) |second| {
                        if (GenerationFact.eql(self.facts.items[second], fact)) return;
                        return;
                    }
                }
                try self.facts.ensureUnusedCapacity(alloc, 1);
                if (existing == null) try self.fact_variants.ensureUnusedCapacity(alloc, 1);
                const owned = try dupeFact(alloc, fact);
                self.facts.appendAssumeCapacity(owned);
                const index = self.facts.items.len - 1;
                if (existing) |variants| {
                    variants.second = index;
                } else {
                    self.fact_variants.putAssumeCapacityNoClobber(owned.id, .{ .first = index });
                }
            },
            .pending => |marker| {
                if (self.coverage_started_at_ms == null) return error.InvalidUsageStore;
                const existing = self.pending_variants.getPtr(marker.id);
                if (existing) |variants| {
                    if (PendingMarker.eql(self.pending.items[variants.first], marker)) return;
                    if (variants.second) |second| {
                        if (PendingMarker.eql(self.pending.items[second], marker)) return;
                        return;
                    }
                }
                try self.pending.ensureUnusedCapacity(alloc, 1);
                try self.incidents.ensureUnusedCapacity(alloc, 1);
                if (existing == null) try self.pending_variants.ensureUnusedCapacity(alloc, 1);
                const id = try alloc.dupe(u8, marker.id);
                self.pending.appendAssumeCapacity(.{ .id = id, .observed_at_ms = marker.observed_at_ms });
                const index = self.pending.items.len - 1;
                if (existing) |variants| {
                    variants.second = index;
                    self.incidents.appendAssumeCapacity(.{
                        .occurred_at_ms = marker.observed_at_ms,
                        .completeness = .incomplete,
                    });
                } else {
                    self.pending_variants.putAssumeCapacityNoClobber(id, .{ .first = index });
                }
            },
            .incident => |incident| try self.incidents.append(alloc, incident),
        }
    }
};

fn dupeFact(alloc: Allocator, fact: GenerationFact) Allocator.Error!GenerationFact {
    const id = try alloc.dupe(u8, fact.id);
    errdefer alloc.free(id);
    var copy = fact;
    copy.id = id;
    copy.model = try alloc.dupe(u8, fact.model);
    return copy;
}

// ---------------------------------------------------------------------------
// Recovery: what marked sessions still owe the profile ledger

/// Borrowed recovered state (fx's `profile_usage_runtime.Recovery`).
pub const Recovery = struct {
    facts: []const GenerationFact = &.{},
    incidents: []const Incident = &.{},
    pending: []const PendingMarker = &.{},
    /// A marker whose session could not be read or proven current, or a
    /// bound was hit. Makes every window `incomplete`.
    unknown_pending: bool = false,

    /// What a failed recovery scan reports (`collectFromHomeConservative`).
    pub const unknown: Recovery = .{ .unknown_pending = true };
};

/// True when a durable session can still owe the profile ledger usage
/// (`session_usage.needsProfileRecovery`).
pub fn needsProfileRecovery(snapshot: *const snapshot_codec.Snapshot) bool {
    return snapshot.settled_through_sequence != snapshot.next_sequence -| 1 or
        snapshot.pending.len > 0 or
        snapshot.publication_backlog.len > 0 or
        snapshot.incidents.len > 0;
}

/// Whether a v1 session's sidecar is at least as new as what its marker
/// protects, from file modification times (`checkpointIsNewer`).
pub fn v1CheckpointIsNewer(
    snapshot: *const snapshot_codec.Snapshot,
    updated_at_ms: i64,
    checkpoint_modified_ns: ?i128,
    marker_modified_ns: i128,
    protected_updated_at_ms: ?i64,
) bool {
    if (!needsProfileRecovery(snapshot)) {
        const modified = checkpoint_modified_ns orelse return false;
        return modified > marker_modified_ns;
    }
    const protected = protected_updated_at_ms orelse return true;
    if (checkpoint_modified_ns) |modified| return modified > marker_modified_ns;
    return updated_at_ms >= protected;
}

/// The same for a sessions-v2 checkpoint (`v2CheckpointIsNewer`).
pub fn v2CheckpointIsNewer(snapshot: *const snapshot_codec.Snapshot, at_ms: i64, protected_updated_at_ms: ?i64) bool {
    const protected = protected_updated_at_ms orelse return false;
    return if (needsProfileRecovery(snapshot)) at_ms >= protected else at_ms > protected;
}

/// Accumulates marked sessions (`collectMarkedSession`). Owns its lists;
/// free with `deinit`.
pub const RecoveryCollector = struct {
    facts: std.ArrayList(GenerationFact) = .empty,
    incidents: std.ArrayList(Incident) = .empty,
    pending: std.ArrayList(PendingMarker) = .empty,
    unknown_pending: bool = false,

    pub fn deinit(self: *RecoveryCollector, alloc: Allocator) void {
        for (self.facts.items) |*fact| fact.deinit(alloc);
        self.facts.deinit(alloc);
        self.incidents.deinit(alloc);
        for (self.pending.items) |*marker| marker.deinit(alloc);
        self.pending.deinit(alloc);
        self.* = undefined;
    }

    /// A marked session whose usage could not be read.
    pub fn markUnknown(self: *RecoveryCollector) void {
        self.unknown_pending = true;
    }

    /// Adds one marked session. `newer` comes from `v1CheckpointIsNewer`
    /// or `v2CheckpointIsNewer`; `updated_at_ms` is the session's update time
    /// (v1) or the checkpoint's `at_ms` (v2). Copies what it keeps.
    pub fn addSession(
        self: *RecoveryCollector,
        alloc: Allocator,
        snapshot: *const snapshot_codec.Snapshot,
        updated_at_ms: i64,
        newer: bool,
    ) Allocator.Error!void {
        if (!newer) self.unknown_pending = true;
        if (!needsProfileRecovery(snapshot)) return;
        if (snapshot.settled_through_sequence != snapshot.next_sequence -| 1) self.unknown_pending = true;
        for (snapshot.publication_backlog) |fact| {
            if (self.facts.items.len == max_recovery_facts) {
                self.unknown_pending = true;
                break;
            }
            try self.facts.ensureUnusedCapacity(alloc, 1);
            self.facts.appendAssumeCapacity(try dupeFact(alloc, fact));
        }
        for (snapshot.incidents) |incident| {
            if (self.incidents.items.len == max_recovery_incidents) {
                self.unknown_pending = true;
                break;
            }
            try self.incidents.append(alloc, incident);
        }
        for (snapshot.pending) |entry| {
            if (self.pending.items.len == max_recovery_pending) {
                self.unknown_pending = true;
                break;
            }
            try self.pending.ensureUnusedCapacity(alloc, 1);
            self.pending.appendAssumeCapacity(.{
                .id = try alloc.dupe(u8, entry.id),
                .observed_at_ms = entry.observed_at_ms orelse @max(updated_at_ms, 0),
            });
        }
        if (snapshot.billing == .incomplete and
            snapshot.incidents.len == 0 and
            snapshot.settled_through_sequence == snapshot.next_sequence -| 1)
        {
            if (self.incidents.items.len == max_recovery_incidents) {
                self.unknown_pending = true;
            } else {
                try self.incidents.append(alloc, .{ .occurred_at_ms = @max(updated_at_ms, 0), .completeness = .incomplete });
            }
        }
    }

    /// A marker that proves a gap but not its contents: a malformed entry
    /// (at its mtime) or an orphan (at its protected time).
    pub fn addIncident(self: *RecoveryCollector, alloc: Allocator, incident: Incident) Allocator.Error!void {
        if (self.incidents.items.len == max_recovery_incidents) {
            self.unknown_pending = true;
            return;
        }
        try self.incidents.append(alloc, incident);
    }

    pub fn recovery(self: *const RecoveryCollector) Recovery {
        return .{
            .facts = self.facts.items,
            .incidents = self.incidents.items,
            .pending = self.pending.items,
            .unknown_pending = self.unknown_pending,
        };
    }
};

// ---------------------------------------------------------------------------
// Rolling views

/// Extra runtime-only input for rolling views. Never persisted.
pub const RollingOptions = struct {
    /// Pending ids a live ledger in this process holds blocked on a 401/403
    ///. They count as `sign_in_cannot_look_up` instead of
    /// `lookup_pending`. Changes no existing output field.
    blocked_ids: []const []const u8 = &.{},
};

/// One rolling view (`profile_usage_runtime.buildSnapshot`). The window is
/// `[snapshot_time_ms - duration, snapshot_time_ms)`. The caller owns the
/// result.
pub fn rollingView(
    alloc: Allocator,
    ledger: LedgerContents,
    recovery: Recovery,
    scope: Scope,
    snapshot_time_ms: i64,
    options: RollingOptions,
) BuildError!View {
    var coverage_started_at_ms = ledger.coverage_started_at_ms;
    for (recovery.facts) |fact| coverage_started_at_ms = minOptional(coverage_started_at_ms, fact.created_at_ms);
    for (recovery.incidents) |incident| coverage_started_at_ms = minOptional(coverage_started_at_ms, incident.occurred_at_ms);
    for (recovery.pending) |marker| coverage_started_at_ms = minOptional(coverage_started_at_ms, marker.observed_at_ms);

    const facts = try alloc.alloc(GenerationFact, ledger.facts.len + recovery.facts.len);
    defer alloc.free(facts);
    @memcpy(facts[0..ledger.facts.len], ledger.facts);
    @memcpy(facts[ledger.facts.len..], recovery.facts);

    var durable_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer durable_ids.deinit(alloc);
    try durable_ids.ensureTotalCapacity(alloc, std.math.cast(u32, ledger.facts.len) orelse return error.UsageCapacityExceeded);
    for (ledger.facts) |fact| durable_ids.putAssumeCapacity(fact.id, {});

    var unknown_pending = recovery.unknown_pending;
    const incidents = try alloc.alloc(
        Incident,
        ledger.incidents.len + recovery.incidents.len + recovery.facts.len +
            ledger.pending.len + recovery.pending.len + 1,
    );
    defer alloc.free(incidents);
    var count: usize = 0;
    for ([_][]const Incident{ ledger.incidents, recovery.incidents }) |list| {
        @memcpy(incidents[count..][0..list.len], list);
        count += list.len;
    }
    for (recovery.facts) |fact| {
        if (durable_ids.contains(fact.id)) continue;
        if (fact.created_at_ms >= snapshot_time_ms) {
            unknown_pending = true;
            continue;
        }
        incidents[count] = .{ .occurred_at_ms = fact.created_at_ms, .completeness = .pending };
        count += 1;
    }
    for ([_][]const PendingMarker{ ledger.pending, recovery.pending }) |markers| {
        for (markers) |marker| {
            if (durable_ids.contains(marker.id)) continue;
            if (marker.observed_at_ms >= snapshot_time_ms) {
                unknown_pending = true;
                continue;
            }
            incidents[count] = .{ .occurred_at_ms = marker.observed_at_ms, .completeness = .pending };
            count += 1;
        }
    }
    if (unknown_pending) {
        incidents[count] = .{ .occurred_at_ms = @max(snapshot_time_ms -| 1, 0), .completeness = .incomplete };
        count += 1;
    }

    var view = try buildRolling(alloc, scope, snapshot_time_ms, coverage_started_at_ms, facts, incidents[0..count]);
    errdefer view.deinit(alloc);
    view.unpriced = try rollingUnpriced(alloc, ledger, recovery, &durable_ids, view.window_start_ms, snapshot_time_ms, options);
    return view;
}

/// The three dashboard views from one ledger read (`rollingSnapshots`),
/// in `Scope.rolling` order. The caller owns all three.
pub fn rollingViews(
    alloc: Allocator,
    ledger: LedgerContents,
    recovery: Recovery,
    snapshot_time_ms: i64,
    options: RollingOptions,
) BuildError![Scope.rolling.len]View {
    var views: [Scope.rolling.len]View = undefined;
    var built: usize = 0;
    errdefer for (views[0..built]) |*view| view.deinit(alloc);
    for (Scope.rolling, 0..) |scope, index| {
        views[index] = try rollingView(alloc, ledger, recovery, scope, snapshot_time_ms, options);
        built += 1;
    }
    return views;
}

fn minOptional(current: ?i64, value: i64) i64 {
    return if (current) |existing| @min(existing, value) else value;
}

fn inWindow(at_ms: i64, window_start_ms: i64, snapshot_time_ms: i64) bool {
    return at_ms >= window_start_ms and at_ms < snapshot_time_ms;
}

fn rollingUnpriced(
    alloc: Allocator,
    ledger: LedgerContents,
    recovery: Recovery,
    durable_ids: *const std.StringHashMapUnmanaged(void),
    window_start_ms: i64,
    snapshot_time_ms: i64,
    options: RollingOptions,
) Allocator.Error!Unpriced {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var lookup_pending: u64 = 0;
    var blocked: u64 = 0;
    for ([_][]const PendingMarker{ ledger.pending, recovery.pending }) |markers| {
        for (markers) |marker| {
            if (durable_ids.contains(marker.id)) continue;
            if (!inWindow(marker.observed_at_ms, window_start_ms, snapshot_time_ms)) continue;
            if ((try seen.getOrPut(alloc, marker.id)).found_existing) continue;
            if (containsId(options.blocked_ids, marker.id)) blocked += 1 else lookup_pending += 1;
        }
    }
    var no_receipt: u64 = 0;
    for ([_][]const Incident{ ledger.incidents, recovery.incidents }) |list| {
        for (list) |incident| {
            if (incident.completeness == .incomplete and inWindow(incident.occurred_at_ms, window_start_ms, snapshot_time_ms)) {
                no_receipt += 1;
            }
        }
    }
    return .fromCounts(lookup_pending, blocked, no_receipt);
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

const MutableTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = 0,
    request_count: u64 = 0,
    total_cost: f64 = 0,

    fn add(self: *MutableTotals, fact: GenerationFact) error{UsageOverflow}!void {
        self.input_tokens = std.math.add(u64, self.input_tokens, fact.input_tokens) catch return error.UsageOverflow;
        self.output_tokens = std.math.add(u64, self.output_tokens, fact.output_tokens) catch return error.UsageOverflow;
        self.cache_read_tokens = std.math.add(u64, self.cache_read_tokens, fact.cache_read_tokens) catch return error.UsageOverflow;
        self.cache_write_tokens = std.math.add(u64, self.cache_write_tokens, fact.cache_write_tokens) catch return error.UsageOverflow;
        self.request_count = std.math.add(u64, self.request_count, 1) catch return error.UsageOverflow;
        // One fact without reasoning makes the whole sum unknown.
        self.reasoning_tokens = if (self.reasoning_tokens) |current|
            if (fact.reasoning_tokens) |reasoning|
                std.math.add(u64, current, reasoning) catch return error.UsageOverflow
            else
                null
        else
            null;
        const next_cost = self.total_cost + fact.total_cost;
        if (!std.math.isFinite(next_cost)) return error.UsageOverflow;
        self.total_cost = next_cost;
    }

    fn freeze(self: MutableTotals) error{UsageOverflow}!Totals {
        return .{
            .total_tokens = std.math.add(u64, self.input_tokens, self.output_tokens) catch return error.UsageOverflow,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            // No requests means nothing measured reasoning.
            .reasoning_tokens = if (self.request_count == 0) null else self.reasoning_tokens,
            .request_count = self.request_count,
            .total_cost = self.total_cost,
        };
    }
};

/// `usage_report.buildRollingSnapshot`.
fn buildRolling(
    alloc: Allocator,
    scope: Scope,
    snapshot_time_ms: i64,
    coverage_started_at_ms: ?i64,
    facts: []const GenerationFact,
    incidents: []const Incident,
) BuildError!View {
    const duration_ms = scope.durationMs() orelse return error.InvalidSnapshotTime;
    if (snapshot_time_ms < 0) return error.InvalidSnapshotTime;
    const window_start_ms = std.math.sub(i64, snapshot_time_ms, duration_ms) catch return error.InvalidSnapshotTime;
    var visible_started_at_ms = coverage_started_at_ms;
    if (coverage_started_at_ms) |started_at_ms| {
        if (started_at_ms < 0) return error.InvalidSnapshotTime;
        // Tracking that starts after this snapshot has not started for it.
        if (started_at_ms > snapshot_time_ms) visible_started_at_ms = null;
    }

    var completeness: Completeness = .complete;
    for (incidents) |incident| {
        if (!inWindow(incident.occurred_at_ms, window_start_ms, snapshot_time_ms)) continue;
        completeness = switch (incident.completeness) {
            .incomplete => .incomplete,
            .pending => if (completeness == .complete) .pending else completeness,
        };
    }

    const coverage: Coverage = if (visible_started_at_ms) |started_at_ms|
        if (started_at_ms <= window_start_ms) .full else .partial
    else
        .not_started;
    if (coverage == .not_started) {
        return emptyView(alloc, scope, snapshot_time_ms, window_start_ms, null, .not_started, completeness);
    }

    var seen: std.StringHashMapUnmanaged(GenerationFact) = .empty;
    defer seen.deinit(alloc);
    try seen.ensureTotalCapacity(alloc, std.math.cast(u32, facts.len) orelse return error.UsageCapacityExceeded);
    var model_indexes: std.StringHashMapUnmanaged(usize) = .empty;
    defer model_indexes.deinit(alloc);
    var rows: std.ArrayList(struct { model: []const u8, totals: MutableTotals }) = .empty;
    defer rows.deinit(alloc);
    var totals: MutableTotals = .{};

    for (facts) |fact| {
        try record.validateFact(fact);
        if (!inWindow(fact.created_at_ms, window_start_ms, snapshot_time_ms)) continue;
        const seen_entry = try seen.getOrPut(alloc, fact.id);
        if (seen_entry.found_existing) {
            // Same id: an exact repeat counts once, a different value
            // means the ledger disagrees with itself.
            if (!GenerationFact.eql(seen_entry.value_ptr.*, fact)) completeness = .incomplete;
            continue;
        }
        seen_entry.value_ptr.* = fact;
        try totals.add(fact);
        const model_entry = try model_indexes.getOrPut(alloc, fact.model);
        if (!model_entry.found_existing) {
            if (rows.items.len == max_models) return error.UsageCapacityExceeded;
            try rows.append(alloc, .{ .model = fact.model, .totals = .{} });
            model_entry.value_ptr.* = rows.items.len - 1;
        }
        try rows.items[model_entry.value_ptr.*].totals.add(fact);
    }

    const models = try alloc.alloc(ModelUsage, rows.items.len);
    var built: usize = 0;
    errdefer {
        for (models[0..built]) |model| alloc.free(model.model);
        alloc.free(models);
    }
    for (rows.items, 0..) |row, index| {
        const frozen = try row.totals.freeze();
        models[index] = .{ .model = try alloc.dupe(u8, row.model), .totals = frozen };
        built += 1;
    }
    sortModels(models);

    return .{
        .scope = scope,
        .snapshot_time_ms = snapshot_time_ms,
        .window_start_ms = window_start_ms,
        .coverage_started_at_ms = visible_started_at_ms,
        .coverage = coverage,
        .completeness = completeness,
        .totals = try totals.freeze(),
        .models = models,
    };
}

fn emptyView(
    alloc: Allocator,
    scope: Scope,
    snapshot_time_ms: i64,
    window_start_ms: i64,
    coverage_started_at_ms: ?i64,
    coverage: Coverage,
    completeness: Completeness,
) Allocator.Error!View {
    return .{
        .scope = scope,
        .snapshot_time_ms = snapshot_time_ms,
        .window_start_ms = window_start_ms,
        .coverage_started_at_ms = coverage_started_at_ms,
        .coverage = coverage,
        .completeness = completeness,
        .totals = null,
        .models = try alloc.alloc(ModelUsage, 0),
    };
}

fn modelLessThan(_: void, first: ModelUsage, second: ModelUsage) bool {
    if (first.totals.total_tokens != second.totals.total_tokens) {
        return first.totals.total_tokens > second.totals.total_tokens;
    }
    if (first.totals.total_cost != second.totals.total_cost) {
        return first.totals.total_cost > second.totals.total_cost;
    }
    return std.mem.order(u8, first.model, second.model) == .lt;
}

/// Stable, like fx's `sort_utils.sort`, so equal session rows keep their
/// order.
fn sortModels(models: []ModelUsage) void {
    std.sort.insertion(ModelUsage, models, {}, modelLessThan);
}

// ---------------------------------------------------------------------------
// Session views

pub const SessionModel = struct {
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    request_count: ?u64,
};

/// The session aggregate, copied into the view unchanged
/// (`usage_report.SessionSource`).
pub const SessionSource = struct {
    snapshot_time_ms: i64,
    session_started_at_ms: i64,
    completeness: Completeness,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    request_count: ?u64,
    models: []const SessionModel,
    activity: SessionActivity,
    unpriced: Unpriced = .none,
    turn: TurnUsage = .{},
};

/// The session view (`buildSessionSnapshot`). Session arithmetic is copied,
/// never rebuilt from the rows. Coverage is always `full`. A legacy session
/// has no totals and keeps only its activity. The caller owns the result.
pub fn sessionView(alloc: Allocator, source: SessionSource) BuildError!View {
    if (source.snapshot_time_ms < 0 or
        source.session_started_at_ms < 0 or
        source.session_started_at_ms > source.snapshot_time_ms or
        !std.math.isFinite(source.total_cost) or
        source.total_cost < 0 or
        source.cache_read_tokens > source.input_tokens or
        source.cache_write_tokens > source.input_tokens)
    {
        return error.InvalidSnapshotTime;
    }
    if (source.reasoning_tokens) |reasoning| {
        if (reasoning > source.output_tokens) return error.InvalidGenerationFact;
    }

    if (source.completeness == .legacy) {
        var view = try emptyView(alloc, .session, source.snapshot_time_ms, source.session_started_at_ms, source.session_started_at_ms, .full, .legacy);
        view.session_activity = source.activity;
        view.unpriced = source.unpriced;
        view.turn = source.turn;
        return view;
    }
    if (source.models.len > max_models) return error.UsageCapacityExceeded;

    const total_tokens = std.math.add(u64, source.input_tokens, source.output_tokens) catch return error.UsageOverflow;
    const models = try alloc.alloc(ModelUsage, source.models.len);
    var built: usize = 0;
    errdefer {
        for (models[0..built]) |model| alloc.free(model.model);
        alloc.free(models);
    }
    for (source.models, 0..) |model, index| {
        if (model.model.len == 0 or
            model.model.len > max_model_bytes or
            !std.math.isFinite(model.total_cost) or
            model.total_cost < 0 or
            model.cache_read_tokens > model.input_tokens or
            model.cache_write_tokens > model.input_tokens)
        {
            return error.InvalidGenerationFact;
        }
        if (model.reasoning_tokens) |reasoning| {
            if (reasoning > model.output_tokens) return error.InvalidGenerationFact;
        }
        for (model.model) |byte| {
            if (byte < 0x21 or byte > 0x7e) return error.InvalidGenerationFact;
        }
        const model_total = std.math.add(u64, model.input_tokens, model.output_tokens) catch return error.UsageOverflow;
        models[index] = .{
            .model = try alloc.dupe(u8, model.model),
            .totals = .{
                .total_tokens = model_total,
                .input_tokens = model.input_tokens,
                .output_tokens = model.output_tokens,
                .cache_read_tokens = model.cache_read_tokens,
                .cache_write_tokens = model.cache_write_tokens,
                .reasoning_tokens = model.reasoning_tokens,
                .request_count = model.request_count,
                .total_cost = model.total_cost,
            },
        };
        built += 1;
    }
    sortModels(models);

    return .{
        .scope = .session,
        .snapshot_time_ms = source.snapshot_time_ms,
        .window_start_ms = source.session_started_at_ms,
        .coverage_started_at_ms = source.session_started_at_ms,
        .coverage = .full,
        .completeness = source.completeness,
        .totals = .{
            .total_tokens = total_tokens,
            .input_tokens = source.input_tokens,
            .output_tokens = source.output_tokens,
            .cache_read_tokens = source.cache_read_tokens,
            .cache_write_tokens = source.cache_write_tokens,
            .reasoning_tokens = source.reasoning_tokens,
            .request_count = source.request_count,
            .total_cost = source.total_cost,
        },
        .models = models,
        .session_activity = source.activity,
        .unpriced = source.unpriced,
        .turn = source.turn,
    };
}

pub fn billingCompleteness(billing: snapshot_codec.Billing) Completeness {
    return switch (billing) {
        .complete => .complete,
        .pending => .pending,
        .incomplete => .incomplete,
        .legacy => .legacy,
    };
}

/// The session view from a session snapshot (`Usage.reportSnapshot`). The
/// session "start" is `snapshot_time_ms` minus the wall time, floored at 0;
/// a wall time beyond `i64` counts as the whole snapshot time.
pub fn sessionViewFromSnapshot(
    alloc: Allocator,
    snapshot: *const snapshot_codec.Snapshot,
    snapshot_time_ms: i64,
    unpriced: Unpriced,
    turn: TurnUsage,
) BuildError!View {
    const models = try alloc.alloc(SessionModel, snapshot.models.len);
    defer alloc.free(models);
    for (snapshot.models, models) |model, *out| {
        out.* = .{
            .model = model.model,
            .total_cost = model.total_cost,
            .input_tokens = model.input_tokens,
            .output_tokens = model.output_tokens,
            .cache_read_tokens = model.cache_read_tokens,
            .cache_write_tokens = model.cache_write_tokens,
            .reasoning_tokens = model.reasoning_tokens,
            .request_count = model.request_count,
        };
    }
    const wall_ms = std.math.cast(i64, snapshot.wall_duration_ms) orelse snapshot_time_ms;
    return sessionView(alloc, .{
        .snapshot_time_ms = snapshot_time_ms,
        .session_started_at_ms = @max(snapshot_time_ms -| wall_ms, 0),
        .completeness = billingCompleteness(snapshot.billing),
        .total_cost = snapshot.total_cost,
        .input_tokens = snapshot.input_tokens,
        .output_tokens = snapshot.output_tokens,
        .cache_read_tokens = snapshot.cache_read_tokens,
        .cache_write_tokens = snapshot.cache_write_tokens,
        .reasoning_tokens = snapshot.reasoning_tokens,
        .request_count = snapshot.request_count,
        .models = models,
        .activity = .{
            .api_duration_complete = snapshot.api_duration_complete,
            .wall_duration_complete = snapshot.wall_duration_complete,
            .code_complete = snapshot.code_complete,
            .api_duration_ms = snapshot.api_duration_ms,
            .wall_duration_ms = snapshot.wall_duration_ms,
            .lines_added = snapshot.lines_added,
            .lines_removed = snapshot.lines_removed,
        },
        .unpriced = unpriced,
        .turn = turn,
    });
}

/// The session spend ACP may report: only when the session is complete and
/// the total is finite (`liveContextSnapshot`).
pub fn completeCost(view: *const View) ?f64 {
    if (view.completeness != .complete) return null;
    const totals = view.totals orelse return null;
    return if (std.math.isFinite(totals.total_cost)) totals.total_cost else null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const day = std.time.ms_per_day;
const hour = std.time.ms_per_hour;

fn testFact(id: []const u8, model: []const u8, created_at_ms: i64, input: u64, output: u64, cost: f64) GenerationFact {
    return .{
        .id = id,
        .created_at_ms = created_at_ms,
        .model = model,
        .input_tokens = input,
        .output_tokens = output,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = 0,
        .total_cost = cost,
    };
}

const id_a = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV";
const id_b = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW";
const id_c = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAX";
const id_d = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAY";

fn rolling(scope: Scope, now: i64, ledger: LedgerContents, recovery: Recovery) !View {
    return rollingView(testing.allocator, ledger, recovery, scope, now, .{});
}

test "windows are half-open: the window start is in, the snapshot time is out" {
    const now = 40 * day;
    inline for (.{ Scope.hours_24, Scope.days_7, Scope.days_30 }) |scope| {
        const start = now - scope.durationMs().?;
        const facts = [_]GenerationFact{
            testFact(id_a, "p/in-first", start, 1, 0, 1),
            testFact(id_b, "p/in-last", now - 1, 2, 0, 1),
            testFact(id_c, "p/before", start - 1, 100, 0, 1),
            testFact(id_d, "p/at-now", now, 100, 0, 1),
        };
        var view = try rolling(scope, now, .{ .coverage_started_at_ms = 0, .facts = &facts }, .{});
        defer view.deinit(testing.allocator);
        try testing.expectEqual(start, view.window_start_ms);
        try testing.expectEqual(@as(u64, 3), view.totals.?.total_tokens);
        try testing.expectEqual(@as(?u64, 2), view.totals.?.request_count);
        try testing.expectEqual(@as(usize, 2), view.models.len);
        try testing.expectEqualStrings("p/in-last", view.models[0].model);
    }
}

test "incidents count only inside the half-open window" {
    const now = 40 * day;
    const start = now - day;
    const cases = [_]struct { at: i64, want: Completeness }{
        .{ .at = start - 1, .want = .complete },
        .{ .at = start, .want = .incomplete },
        .{ .at = now - 1, .want = .incomplete },
        .{ .at = now, .want = .complete },
    };
    for (cases) |case| {
        var view = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .incidents = &.{.{ .occurred_at_ms = case.at, .completeness = .incomplete }} }, .{});
        defer view.deinit(testing.allocator);
        try testing.expectEqual(case.want, view.completeness);
        try testing.expectEqual(@as(u64, @intFromBool(case.want == .incomplete)), view.unpriced.no_receipt);
    }
}

test "coverage boundaries: full at the window start, partial after, not started after the snapshot" {
    const now = 40 * day;
    const start = now - 7 * day;
    const cases = [_]struct { started: ?i64, want: Coverage, shown: ?i64 }{
        .{ .started = null, .want = .not_started, .shown = null },
        .{ .started = 0, .want = .full, .shown = 0 },
        .{ .started = start, .want = .full, .shown = start },
        .{ .started = start + 1, .want = .partial, .shown = start + 1 },
        .{ .started = now, .want = .partial, .shown = now },
        .{ .started = now + 1, .want = .not_started, .shown = null },
    };
    for (cases) |case| {
        var view = try rolling(.days_7, now, .{ .coverage_started_at_ms = case.started }, .{});
        defer view.deinit(testing.allocator);
        try testing.expectEqual(case.want, view.coverage);
        try testing.expectEqual(case.shown, view.coverage_started_at_ms);
        try testing.expectEqual(case.want == .not_started, view.totals == null);
    }
    try testing.expectError(error.InvalidSnapshotTime, rolling(.days_7, now, .{ .coverage_started_at_ms = -1 }, .{}));
    try testing.expectError(error.InvalidSnapshotTime, rolling(.days_7, -1, .{}, .{}));
    try testing.expectError(error.InvalidSnapshotTime, rolling(.session, now, .{}, .{}));
    try testing.expectError(error.InvalidSnapshotTime, rolling(.days_30, std.math.minInt(i64) + 1, .{}, .{}));
}

test "not started still reports completeness from incidents" {
    const now = 40 * day;
    var view = try rolling(.days_7, now, .{ .incidents = &.{.{ .occurred_at_ms = now - 1, .completeness = .incomplete }} }, .{});
    defer view.deinit(testing.allocator);
    try testing.expectEqual(Coverage.not_started, view.coverage);
    try testing.expectEqual(Completeness.incomplete, view.completeness);
}

test "dedupe: exact repeats count once, conflicts make the window incomplete" {
    const now = 40 * day;
    const original = testFact(id_a, "p/m", now - 1, 4, 2, 0.5);
    var conflict = original;
    conflict.output_tokens = 3;
    var exact = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .facts = &.{ original, original } }, .{});
    defer exact.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 6), exact.totals.?.total_tokens);
    try testing.expectEqual(Completeness.complete, exact.completeness);
    var conflicted = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .facts = &.{ original, conflict } }, .{});
    defer conflicted.deinit(testing.allocator);
    try testing.expectEqual(Completeness.incomplete, conflicted.completeness);
    try testing.expectEqual(@as(u64, 6), conflicted.totals.?.total_tokens);
}

test "model order: tokens, then cost, both descending, then name" {
    const now = 40 * day;
    const facts = [_]GenerationFact{
        testFact(id_a, "z/model", now - 3, 3, 2, 1),
        testFact(id_b, "b/model", now - 2, 5, 5, 2),
        testFact(id_c, "a/model", now - 1, 5, 5, 2),
        testFact(id_d, "c/model", now - 1, 5, 5, 3),
    };
    var view = try rolling(.days_30, now, .{ .coverage_started_at_ms = 0, .facts = &facts }, .{});
    defer view.deinit(testing.allocator);
    const want = [_][]const u8{ "c/model", "a/model", "b/model", "z/model" };
    for (want, view.models) |name, model| try testing.expectEqualStrings(name, model.model);
}

test "reasoning becomes unknown when any fact lacks it, and with no requests" {
    const now = 40 * day;
    var with = testFact(id_a, "p/m", now - 1, 4, 2, 0);
    with.reasoning_tokens = 1;
    var without = testFact(id_b, "p/m", now - 1, 4, 2, 0);
    without.reasoning_tokens = null;
    var mixed = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .facts = &.{ with, without } }, .{});
    defer mixed.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, null), mixed.totals.?.reasoning_tokens);
    var empty = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0 }, .{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, null), empty.totals.?.reasoning_tokens);
    try testing.expectEqual(@as(?u64, 0), empty.totals.?.request_count);
}

test "rolling views hold at most 128 models" {
    const alloc = testing.allocator;
    const now = 40 * day;
    var ids: [max_models + 1][30]u8 = undefined;
    var names: [max_models + 1][7]u8 = undefined;
    var facts: [max_models + 1]GenerationFact = undefined;
    for (&ids, &names, &facts, 0..) |*id, *name, *fact, index| {
        _ = std.fmt.bufPrint(id, "gen_01ARZ3NDEKTSV4RRFFQ69G{d:0>4}", .{index}) catch unreachable;
        _ = std.fmt.bufPrint(name, "p/m{d:0>4}", .{index}) catch unreachable;
        fact.* = testFact(id, name, now - 1, 1, 0, 0);
    }
    var full = try rollingView(alloc, .{ .coverage_started_at_ms = 0, .facts = facts[0..max_models] }, .{}, .hours_24, now, .{});
    defer full.deinit(alloc);
    try testing.expectEqual(max_models, full.models.len);
    try testing.expectError(error.UsageCapacityExceeded, rollingView(alloc, .{ .coverage_started_at_ms = 0, .facts = &facts }, .{}, .hours_24, now, .{}));
}

test "invalid facts fail the view even outside the window" {
    var bad = testFact(id_a, "p/m", 0, 1, 1, 0);
    bad.cache_read_tokens = 2;
    try testing.expectError(error.InvalidGenerationFact, rolling(.hours_24, 40 * day, .{ .coverage_started_at_ms = 0, .facts = &.{bad} }, .{}));
}

test "recovered facts count, extend coverage, and stay pending until durable" {
    const now = 40 * day;
    const recovered = testFact(id_a, "p/m", now - hour, 5, 2, 0.25);
    var view = try rolling(.hours_24, now, .{}, .{ .facts = &.{recovered} });
    defer view.deinit(testing.allocator);
    try testing.expectEqual(Coverage.partial, view.coverage);
    try testing.expectEqual(@as(?i64, now - hour), view.coverage_started_at_ms);
    try testing.expectEqual(Completeness.pending, view.completeness);
    try testing.expectEqual(@as(u64, 7), view.totals.?.total_tokens);

    var settled = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .facts = &.{recovered} }, .{ .facts = &.{recovered} });
    defer settled.deinit(testing.allocator);
    try testing.expectEqual(Completeness.complete, settled.completeness);
    try testing.expectEqual(@as(?u64, 1), settled.totals.?.request_count);
}

test "recovered facts or markers at the snapshot time make every window incomplete" {
    const now = 40 * day;
    const late = testFact(id_a, "p/m", now, 5, 2, 0.25);
    var by_fact = try rolling(.days_30, now, .{ .coverage_started_at_ms = 0 }, .{ .facts = &.{late} });
    defer by_fact.deinit(testing.allocator);
    try testing.expectEqual(Completeness.incomplete, by_fact.completeness);
    try testing.expectEqual(@as(u64, 0), by_fact.totals.?.total_tokens);

    var by_marker = try rolling(.days_30, now, .{ .coverage_started_at_ms = 0, .pending = &.{.{ .id = id_b, .observed_at_ms = now }} }, .{});
    defer by_marker.deinit(testing.allocator);
    try testing.expectEqual(Completeness.incomplete, by_marker.completeness);
    try testing.expectEqual(@as(u64, 0), by_marker.unpriced.lookup_pending);

    var just_before = try rolling(.days_30, now, .{ .coverage_started_at_ms = 0, .pending = &.{.{ .id = id_b, .observed_at_ms = now - 1 }} }, .{});
    defer just_before.deinit(testing.allocator);
    try testing.expectEqual(Completeness.pending, just_before.completeness);
    try testing.expectEqual(@as(u64, 1), just_before.unpriced.lookup_pending);

    var unknown = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0 }, Recovery.unknown);
    defer unknown.deinit(testing.allocator);
    try testing.expectEqual(Completeness.incomplete, unknown.completeness);
    try testing.expectEqual(@as(u64, 0), unknown.unpriced.count);
}

test "unknown pending lands at snapshot minus one, floored at zero" {
    var at_zero = try rolling(.hours_24, 0, .{ .coverage_started_at_ms = 0 }, Recovery.unknown);
    defer at_zero.deinit(testing.allocator);
    // The incident at 0 is outside [-24h, 0), so the window stays complete.
    try testing.expectEqual(Completeness.complete, at_zero.completeness);
    var at_one = try rolling(.hours_24, 1, .{ .coverage_started_at_ms = 0 }, Recovery.unknown);
    defer at_one.deinit(testing.allocator);
    try testing.expectEqual(Completeness.incomplete, at_one.completeness);
}

test "durable facts resolve pending markers" {
    const now = 40 * day;
    const fact = testFact(id_a, "p/m", now - 2 * day, 1, 1, 0);
    var view = try rolling(.hours_24, now, .{ .coverage_started_at_ms = 0, .facts = &.{fact}, .pending = &.{.{ .id = id_a, .observed_at_ms = now - 1 }} }, .{});
    defer view.deinit(testing.allocator);
    try testing.expectEqual(Completeness.complete, view.completeness);
    try testing.expectEqual(Unpriced.none, view.unpriced);
}

test "unpriced: distinct markers in the window, blocked ids first, then incidents" {
    const now = 40 * day;
    const ledger: LedgerContents = .{
        .coverage_started_at_ms = 0,
        .pending = &.{ .{ .id = id_a, .observed_at_ms = now - 2 }, .{ .id = id_a, .observed_at_ms = now - 1 }, .{ .id = id_b, .observed_at_ms = now - 1 }, .{ .id = id_c, .observed_at_ms = now - 2 * day } },
        .incidents = &.{ .{ .occurred_at_ms = now - 1, .completeness = .incomplete }, .{ .occurred_at_ms = now - 1, .completeness = .pending } },
    };
    var plain = try rolling(.hours_24, now, ledger, .{ .pending = &.{.{ .id = id_b, .observed_at_ms = now - 3 }} });
    defer plain.deinit(testing.allocator);
    try testing.expectEqual(Unpriced.fromCounts(2, 0, 1), plain.unpriced);
    try testing.expectEqual(@as(?UnpricedReason, .lookup_pending), plain.unpriced.reason);

    var blocked = try rollingView(testing.allocator, ledger, .{}, .hours_24, now, .{ .blocked_ids = &.{id_b} });
    defer blocked.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), blocked.unpriced.sign_in_cannot_look_up);
    try testing.expectEqual(@as(?UnpricedReason, .sign_in_cannot_look_up), blocked.unpriced.reason);
    try testing.expectEqual(@as(u64, 3), blocked.unpriced.count);

    try testing.expectEqual(@as(?UnpricedReason, .no_receipt), Unpriced.fromCounts(0, 0, 4).reason);
    try testing.expectEqual(@as(?UnpricedReason, null), Unpriced.fromCounts(0, 0, 0).reason);
    try testing.expectEqual(std.math.maxInt(u64), Unpriced.fromCounts(std.math.maxInt(u64), 1, 1).count);
}

test "rolling views come in dashboard order from one read" {
    const now = 40 * day;
    var views = try rollingViews(testing.allocator, .{ .coverage_started_at_ms = 0, .facts = &.{testFact(id_a, "p/m", now - 3 * day, 1, 1, 0)} }, .{}, now, .{});
    defer for (&views) |*view| view.deinit(testing.allocator);
    for (Scope.rolling, views, [_]u64{ 2, 2, 0 }) |scope, view, tokens| {
        try testing.expectEqual(scope, view.scope);
        try testing.expectEqual(tokens, view.totals.?.total_tokens);
    }
}

test "ledger reader: coverage once, records after coverage, two variants, conflict incidents" {
    const alloc = testing.allocator;
    var ledger = try ProfileLedger.load(alloc,
        \\{"schema_version":1,"kind":"coverage","started_at_ms":5}
        \\{"schema_version":1,"kind":"coverage","started_at_ms":5}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":7}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":7}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":8}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":9}
        \\{"schema_version":1,"kind":"generation","fact":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","created_at_ms":6,"model":"p/m","input_tokens":1,"output_tokens":1,"cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,"billable_web_search_calls":0,"total_cost":0}}
        \\{"schema_version":1,"kind":"generation","fact":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","created_at_ms":6,"model":"p/m","input_tokens":1,"output_tokens":2,"cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,"billable_web_search_calls":0,"total_cost":0}}
        \\{"schema_version":1,"kind":"generation","fact":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","created_at_ms":6,"model":"p/m","input_tokens":1,"output_tokens":3,"cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,"billable_web_search_calls":0,"total_cost":0}}
        \\{"schema_version":1,"kind":"incident","occurred_at_ms":10,"completeness":"pending"}
        \\
    );
    defer ledger.deinit(alloc);
    const contents = ledger.contents();
    try testing.expectEqual(@as(?i64, 5), contents.coverage_started_at_ms);
    try testing.expectEqual(@as(usize, 2), contents.pending.len);
    try testing.expectEqual(@as(usize, 2), contents.facts.len);
    try testing.expectEqual(@as(usize, 2), contents.incidents.len);
    try testing.expectEqual(Incident{ .occurred_at_ms = 8, .completeness = .incomplete }, contents.incidents[0]);
    try testing.expectEqual(@as(usize, 10), ledger.record_count);

    const invalid = [_][]const u8{
        "{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":5}\n{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":6}\n",
        "{\"schema_version\":1,\"kind\":\"pending\",\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"observed_at_ms\":7}\n",
        "{\"schema_version\":2,\"kind\":\"coverage\",\"started_at_ms\":5}\n",
    };
    for (invalid) |bytes| try testing.expectError(error.InvalidUsageStore, ProfileLedger.load(alloc, bytes));
    try testing.expectError(error.UsageStoreIncomplete, ProfileLedger.load(alloc, "{\"schema_version\":1"));
    var empty = try ProfileLedger.load(alloc, "");
    defer empty.deinit(alloc);
    try testing.expectEqual(@as(?i64, null), empty.coverage_started_at_ms);
    var blank = try ProfileLedger.load(alloc, "\n\n");
    defer blank.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), blank.record_count);
}

test "ledger reader rejects oversized lines" {
    const alloc = testing.allocator;
    const line = try alloc.alloc(u8, record.max_record_bytes + 2);
    defer alloc.free(line);
    @memset(line, ' ');
    line[line.len - 1] = '\n';
    try testing.expectError(error.UsageCapacityExceeded, ProfileLedger.load(alloc, line));
}

test "ledger reader frees everything on every allocation failure" {
    const bytes =
        \\{"schema_version":1,"kind":"coverage","started_at_ms":5}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":7}
        \\{"schema_version":1,"kind":"pending","id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","observed_at_ms":8}
        \\{"schema_version":1,"kind":"generation","fact":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","created_at_ms":6,"model":"p/m","input_tokens":1,"output_tokens":1,"cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,"billable_web_search_calls":0,"total_cost":0}}
        \\{"schema_version":1,"kind":"incident","occurred_at_ms":10,"completeness":"pending"}
        \\
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator, input: []const u8) !void {
            var ledger = try ProfileLedger.load(alloc, input);
            defer ledger.deinit(alloc);
            var view = try rollingView(alloc, ledger.contents(), .{}, .days_30, 40 * day, .{});
            view.deinit(alloc);
        }
    }.run, .{bytes});
}

fn testSnapshot() snapshot_codec.Snapshot {
    var snapshot = snapshot_codec.legacy_unavailable;
    snapshot.billing = .complete;
    snapshot.next_sequence = 2;
    snapshot.settled_through_sequence = 1;
    return snapshot;
}

test "recovery: settled sessions owe nothing, owed sessions give backlog, incidents, and markers" {
    const alloc = testing.allocator;
    var collector: RecoveryCollector = .{};
    defer collector.deinit(alloc);

    const settled = testSnapshot();
    try collector.addSession(alloc, &settled, 100, true);
    try testing.expectEqual(Recovery{}, collector.recovery());

    var owed = testSnapshot();
    owed.billing = .pending;
    owed.publication_backlog = &.{testFact(id_a, "p/m", 50, 1, 1, 0)};
    owed.pending = &.{ .{ .id = id_a, .sequence = 1, .origin = "exact/gateway", .team = null, .observed_at_ms = 60 }, .{ .id = id_b, .sequence = 1, .origin = "exact/gateway", .team = null } };
    owed.incidents = &.{.{ .occurred_at_ms = 70, .completeness = .pending }};
    try collector.addSession(alloc, &owed, -5, true);
    const recovery = collector.recovery();
    try testing.expectEqual(@as(usize, 1), recovery.facts.len);
    try testing.expectEqual(@as(usize, 1), recovery.incidents.len);
    try testing.expectEqual(@as(i64, 60), recovery.pending[0].observed_at_ms);
    // A missing observation time falls back to the update time, floored at 0.
    try testing.expectEqual(@as(i64, 0), recovery.pending[1].observed_at_ms);
    try testing.expect(!recovery.unknown_pending);
}

test "recovery: incomplete sessions get one incident, gaps and stale checkpoints are unknown" {
    const alloc = testing.allocator;
    var collector: RecoveryCollector = .{};
    defer collector.deinit(alloc);

    var incomplete = testSnapshot();
    incomplete.billing = .incomplete;
    incomplete.next_sequence = 3; // settled 1 of 2: a gap
    try collector.addSession(alloc, &incomplete, 100, true);
    try testing.expect(collector.unknown_pending);
    try testing.expectEqual(@as(usize, 0), collector.incidents.items.len);

    var clean: RecoveryCollector = .{};
    defer clean.deinit(alloc);
    var marked = testSnapshot();
    marked.billing = .incomplete;
    // Needs recovery only because of its incident; billing incomplete with an
    // incident gets no synthetic one.
    marked.incidents = &.{.{ .occurred_at_ms = 9, .completeness = .incomplete }};
    try clean.addSession(alloc, &marked, 100, true);
    try testing.expectEqual(@as(usize, 1), clean.incidents.items.len);
    try testing.expect(!clean.unknown_pending);

    var stale: RecoveryCollector = .{};
    defer stale.deinit(alloc);
    const settled = testSnapshot();
    try stale.addSession(alloc, &settled, 100, false);
    try testing.expect(stale.unknown_pending);
}

test "recovery: checkpoint freshness rules" {
    const settled = testSnapshot();
    var owed = testSnapshot();
    owed.pending = &.{.{ .id = id_a, .sequence = 1, .origin = "o", .team = null }};
    try testing.expect(!v1CheckpointIsNewer(&settled, 0, null, 5, 1));
    try testing.expect(!v1CheckpointIsNewer(&settled, 0, 5, 5, 1));
    try testing.expect(v1CheckpointIsNewer(&settled, 0, 6, 5, 1));
    try testing.expect(v1CheckpointIsNewer(&owed, 0, null, 5, null));
    try testing.expect(!v1CheckpointIsNewer(&owed, 0, 5, 5, 1));
    try testing.expect(v1CheckpointIsNewer(&owed, 1, null, 5, 1));
    try testing.expect(!v1CheckpointIsNewer(&owed, 0, null, 5, 1));
    try testing.expect(!v2CheckpointIsNewer(&owed, 9, null));
    try testing.expect(v2CheckpointIsNewer(&owed, 9, 9));
    try testing.expect(!v2CheckpointIsNewer(&settled, 9, 9));
    try testing.expect(v2CheckpointIsNewer(&settled, 10, 9));
}

test "recovery bounds: 4096 entries, then unknown pending" {
    const alloc = testing.allocator;
    var collector: RecoveryCollector = .{};
    defer collector.deinit(alloc);
    var incidents: [max_recovery_incidents + 1]Incident = undefined;
    @memset(&incidents, .{ .occurred_at_ms = 1, .completeness = .pending });
    var owed = testSnapshot();
    owed.incidents = &incidents;
    try collector.addSession(alloc, &owed, 0, true);
    try testing.expectEqual(max_recovery_incidents, collector.incidents.items.len);
    try testing.expect(collector.unknown_pending);
}

fn testActivity() SessionActivity {
    return .{ .api_duration_complete = true, .wall_duration_complete = false, .code_complete = true, .api_duration_ms = 1200, .wall_duration_ms = 3400, .lines_added = 5, .lines_removed = 2 };
}

fn testSource(completeness: Completeness) SessionSource {
    return .{
        .snapshot_time_ms = 200,
        .session_started_at_ms = 100,
        .completeness = completeness,
        .total_cost = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .request_count = null,
        .models = &.{},
        .activity = testActivity(),
    };
}

test "session views copy totals, keep activity, and drop totals only for legacy" {
    const alloc = testing.allocator;
    for ([_]Completeness{ .complete, .pending, .incomplete }) |completeness| {
        var view = try sessionView(alloc, testSource(completeness));
        defer view.deinit(alloc);
        try testing.expectEqual(Coverage.full, view.coverage);
        try testing.expectEqual(@as(u64, 0), view.totals.?.total_tokens);
        try testing.expectEqual(testActivity(), view.session_activity.?);
        try testing.expectEqual(@as(i64, 100), view.window_start_ms);
    }
    var legacy = try sessionView(alloc, testSource(.legacy));
    defer legacy.deinit(alloc);
    try testing.expect(legacy.totals == null);
    try testing.expectEqual(testActivity(), legacy.session_activity.?);
    try testing.expectEqual(@as(?f64, null), completeCost(&legacy));
}

test "session views validate like fx" {
    const alloc = testing.allocator;
    var source = testSource(.complete);
    source.session_started_at_ms = 201;
    try testing.expectError(error.InvalidSnapshotTime, sessionView(alloc, source));
    source = testSource(.complete);
    source.reasoning_tokens = 1;
    try testing.expectError(error.InvalidGenerationFact, sessionView(alloc, source));
    source = testSource(.complete);
    source.input_tokens = 1;
    source.models = &.{.{ .model = "bad model", .total_cost = 0, .input_tokens = 1, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .request_count = null }};
    try testing.expectError(error.InvalidGenerationFact, sessionView(alloc, source));
    source.models = &.{.{ .model = "p/m", .total_cost = 0, .input_tokens = 1, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .request_count = null }};
    var ok = try sessionView(alloc, source);
    ok.deinit(alloc);
    // Legacy skips model checks entirely.
    source.completeness = .legacy;
    source.models = &.{.{ .model = "bad model", .total_cost = 0, .input_tokens = 0, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .request_count = null }};
    var legacy = try sessionView(alloc, source);
    legacy.deinit(alloc);
}

test "session view from a snapshot: start is now minus wall time, cost only when complete" {
    const alloc = testing.allocator;
    var snapshot = testSnapshot();
    snapshot.wall_duration_ms = 300;
    snapshot.total_cost = 0.5;
    var view = try sessionViewFromSnapshot(alloc, &snapshot, 1000, .none, .{ .input_tokens = 3 });
    defer view.deinit(alloc);
    try testing.expectEqual(@as(i64, 700), view.window_start_ms);
    try testing.expectEqual(@as(?f64, 0.5), completeCost(&view));
    try testing.expectEqual(@as(?u64, 3), view.turn.?.input_tokens);

    snapshot.wall_duration_ms = std.math.maxInt(u64);
    snapshot.billing = .pending;
    var floored = try sessionViewFromSnapshot(alloc, &snapshot, 1000, .none, .{});
    defer floored.deinit(alloc);
    try testing.expectEqual(@as(i64, 0), floored.window_start_ms);
    try testing.expectEqual(@as(?f64, null), completeCost(&floored));
}

test "turn usage sums reported counts and saturates" {
    var turn: TurnUsage = .{};
    turn.add(.{ .input_tokens = 3 });
    turn.add(.{ .input_tokens = 4, .output_tokens = 2 });
    try testing.expectEqual(TurnUsage{ .input_tokens = 7, .output_tokens = 2 }, turn);
    turn.add(.{ .input_tokens = std.math.maxInt(u64) });
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), turn.input_tokens);
}

test "scope navigation follows the on-screen tab order" {
    // Right from the session: 24 hours, 7 days, 30 days, then stays.
    var scope: Scope = .session;
    for ([_]Scope{ .hours_24, .days_7, .days_30, .days_30 }) |want| {
        scope = scope.next();
        try testing.expectEqual(want, scope);
    }
    // Left from 30 days: back to the session, then stays.
    for ([_]Scope{ .days_7, .hours_24, .session, .session }) |want| {
        scope = scope.previous();
        try testing.expectEqual(want, scope);
    }
    // Tab moves like Right and wraps.
    for ([_]Scope{ .hours_24, .days_7, .days_30, .session }) |want| {
        scope = scope.cycle(.forward);
        try testing.expectEqual(want, scope);
    }
    for ([_]Scope{ .days_30, .days_7, .hours_24, .session }) |want| {
        scope = scope.cycle(.backward);
        try testing.expectEqual(want, scope);
    }
    try testing.expectEqualSlices(Scope, &.{ .session, .hours_24, .days_7, .days_30 }, &Scope.tab_order);
    try testing.expectEqual(@as(?Scope, .days_7), Scope.fromCliValue("7d"));
    try testing.expectEqual(@as(?Scope, null), Scope.fromCliValue("session"));
}

test "dates format like fx" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("Oct 7, 2026", formatUtcDate(&buf, 1791381023000));
    try testing.expectEqualStrings("Jan 1, 1970", formatUtcDate(&buf, 0));
    try testing.expectEqualStrings("Unknown", formatUtcDate(&buf, -1));
    try testing.expectEqualStrings("Feb 29, 2024", formatUtcDate(&buf, 1709251199999));
}
