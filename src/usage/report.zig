//! Reports: the one `View` every usage surface draws, built from the
//! session ledger or from AI Gateway's usage reports.
//!
//! The rules are the ones older fx binaries used, so every surface shows the
//! same numbers: scopes and their tab order, UTC dates, totals arithmetic,
//! model order and caps, a session's start (now minus wall time), and a live
//! cost only when complete.
//!
//! `View.unpriced` says which calls are missing from a session's totals and
//! why; session views take the ledger core's count unchanged.
//!
//! Pure: no I/O, no clock. Views own their model names; free with `deinit`.

const std = @import("std");
const record = @import("codec/record.zig");
const snapshot_codec = @import("codec/snapshot.zig");
const ledger_core = @import("core/ledger.zig");
const gateway_history = @import("gateway_history.zig");

const Allocator = std.mem.Allocator;

pub const Incident = record.Incident;
pub const UnpricedReason = ledger_core.UnpricedReason;

/// Most model rows one view holds (`usage_report.max_models`).
pub const max_models: usize = 128;
/// Longest model name a session source may carry.
pub const max_model_bytes: usize = record.max_model_bytes;

// ---------------------------------------------------------------------------
// Scopes

pub const Scope = enum {
    session,
    today,
    days_7,
    days_30,

    /// Rolling scopes in the order the dashboard loads them.
    pub const rolling = [_]Scope{ .days_30, .days_7, .today };
    /// Dashboard period order, left to right: the session first, since the
    /// dashboard opens on it.
    pub const tab_order = [_]Scope{ .session, .today, .days_7, .days_30 };

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .session => "Session",
            .today => "Today",
            .days_7 => "7 days",
            .days_30 => "30 days",
        };
    }

    /// The `--period` value, or null for the session.
    pub fn cliValue(self: Scope) ?[]const u8 {
        return switch (self) {
            .session => null,
            .today => "today",
            .days_7 => "7d",
            .days_30 => "30d",
        };
    }

    /// Parses a `--period` value. `session` is not a period.
    pub fn fromCliValue(text: []const u8) ?Scope {
        inline for (.{ Scope.today, Scope.days_7, Scope.days_30 }) |scope| {
            if (std.mem.eql(u8, text, scope.cliValue().?)) return scope;
        }
        return null;
    }

    /// Window length, or null for the session.
    pub fn durationMs(self: Scope) ?i64 {
        return switch (self) {
            .session => null,
            .today => std.time.ms_per_hour * 24,
            .days_7 => std.time.ms_per_day * 7,
            .days_30 => std.time.ms_per_day * 30,
        };
    }

    /// The Left key. Periods read session today 7d 30d left to right, so Left
    /// moves toward the session, without wrapping.
    pub fn previous(self: Scope) Scope {
        return switch (self) {
            .session => .session,
            .today => .session,
            .days_7 => .today,
            .days_30 => .days_7,
        };
    }

    /// The Right key: toward 30 days, without wrapping. Tab moves the same
    /// way and wraps.
    pub fn next(self: Scope) Scope {
        return switch (self) {
            .session => .today,
            .today => .days_7,
            .days_7 => .days_30,
            .days_30 => .days_30,
        };
    }

    pub const Direction = enum { forward, backward };

    /// Tab (`forward`) and Shift+Tab (`backward`), wrapping:
    /// session → today → 7d → 30d → session.
    pub fn cycle(self: Scope, direction: Direction) Scope {
        return switch (direction) {
            .forward => switch (self) {
                .session => .today,
                .today => .days_7,
                .days_7 => .days_30,
                .days_30 => .session,
            },
            .backward => switch (self) {
                .session => .days_30,
                .today => .session,
                .days_7 => .today,
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
    /// History views only: where the numbers come from.
    history: ?History = null,

    pub fn deinit(self: *View, alloc: Allocator) void {
        for (self.models) |model| alloc.free(model.model);
        alloc.free(self.models);
        self.* = undefined;
    }
};

/// Where a history view's numbers come from.
pub const History = struct {
    /// When AI Gateway sent the numbers. Null when there are none.
    as_of_ms: ?i64 = null,
    /// Why there are no numbers. Null when there are.
    unavailable: ?Unavailable = null,
    /// The last refresh failed, so the numbers, if any, are older.
    refresh_failed: bool = false,
};

/// Why a history view has no numbers.
pub const Unavailable = enum {
    /// The credential has no API key to tag: a sign-in or a deployment
    /// token.
    needs_api_key,
    /// A ChatGPT or Grok subscription, whose usage never reaches AI Gateway.
    subscription,
    /// AI Gateway refused usage reports for this credential.
    refused,
    /// No snapshot yet, and the refresh failed.
    failed,
};

/// A history view from AI Gateway's rows for `scope`, covering whole UTC
/// days from `first_day` through the day the snapshot was taken. The
/// totals add every row; the list keeps the `max_models` largest. The
/// caller owns the result.
pub fn historyView(
    alloc: Allocator,
    scope: Scope,
    rows: []const gateway_history.Row,
    as_of_ms: i64,
    first_day: i64,
    refresh_failed: bool,
) BuildError!View {
    if (scope == .session or as_of_ms < 0 or first_day < 0) return error.InvalidSnapshotTime;
    var totals: Totals = .{
        .total_tokens = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = 0,
        .request_count = 0,
        .total_cost = 0,
    };
    const models = try alloc.alloc(ModelUsage, rows.len);
    var built: usize = 0;
    errdefer {
        for (models[0..built]) |model| alloc.free(model.model);
        alloc.free(models);
    }
    for (rows, models) |row, *model| {
        const one: Totals = .{
            .total_tokens = std.math.add(u64, row.input_tokens, row.output_tokens) catch return error.UsageOverflow,
            .input_tokens = row.input_tokens,
            .output_tokens = row.output_tokens,
            .cache_read_tokens = row.cache_read_tokens,
            .cache_write_tokens = row.cache_write_tokens,
            .reasoning_tokens = row.reasoning_tokens,
            .request_count = row.request_count,
            .total_cost = row.total_cost,
        };
        try addTotals(&totals, one);
        model.* = .{ .model = try alloc.dupe(u8, row.model), .totals = one };
        built += 1;
    }
    sortModels(models);
    const kept = @min(models.len, max_models);
    for (models[kept..]) |model| alloc.free(model.model);
    const listed = if (alloc.resize(models, kept)) models[0..kept] else blk: {
        const smaller = try alloc.dupe(ModelUsage, models[0..kept]);
        alloc.free(models);
        break :blk smaller;
    };
    return .{
        .scope = scope,
        .snapshot_time_ms = as_of_ms,
        .window_start_ms = first_day * std.time.ms_per_day,
        .coverage_started_at_ms = null,
        .coverage = .full,
        .completeness = .complete,
        .totals = totals,
        .models = listed,
        .history = .{ .as_of_ms = as_of_ms, .refresh_failed = refresh_failed },
    };
}

/// Adds `part` into `sum`. Both carry reasoning and request counts.
fn addTotals(sum: *Totals, part: Totals) error{UsageOverflow}!void {
    inline for (.{ "total_tokens", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens" }) |field| {
        @field(sum, field) = std.math.add(u64, @field(sum, field), @field(part, field)) catch return error.UsageOverflow;
    }
    sum.reasoning_tokens = std.math.add(u64, sum.reasoning_tokens.?, part.reasoning_tokens.?) catch return error.UsageOverflow;
    sum.request_count = std.math.add(u64, sum.request_count.?, part.request_count.?) catch return error.UsageOverflow;
    const cost = sum.total_cost + part.total_cost;
    if (!std.math.isFinite(cost)) return error.UsageOverflow;
    sum.total_cost = cost;
}

/// A history view with no numbers, saying why. The caller owns the result.
pub fn unavailableView(alloc: Allocator, scope: Scope, now_ms: i64, reason: Unavailable) Allocator.Error!View {
    return .{
        .scope = scope,
        .snapshot_time_ms = now_ms,
        .window_start_ms = now_ms,
        .coverage_started_at_ms = null,
        .coverage = .full,
        .completeness = .complete,
        .totals = null,
        .models = try alloc.alloc(ModelUsage, 0),
        .history = .{ .unavailable = reason },
    };
}

pub const BuildError = Allocator.Error || error{
    InvalidGenerationFact,
    InvalidSnapshotTime,
    UsageCapacityExceeded,
    UsageOverflow,
};

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

fn testSnapshot() snapshot_codec.Snapshot {
    var snapshot = snapshot_codec.legacy_unavailable;
    snapshot.billing = .complete;
    snapshot.next_sequence = 2;
    snapshot.settled_through_sequence = 1;
    return snapshot;
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
    for ([_]Scope{ .today, .days_7, .days_30, .days_30 }) |want| {
        scope = scope.next();
        try testing.expectEqual(want, scope);
    }
    // Left from 30 days: back to the session, then stays.
    for ([_]Scope{ .days_7, .today, .session, .session }) |want| {
        scope = scope.previous();
        try testing.expectEqual(want, scope);
    }
    // Tab moves like Right and wraps.
    for ([_]Scope{ .today, .days_7, .days_30, .session }) |want| {
        scope = scope.cycle(.forward);
        try testing.expectEqual(want, scope);
    }
    for ([_]Scope{ .days_30, .days_7, .today, .session }) |want| {
        scope = scope.cycle(.backward);
        try testing.expectEqual(want, scope);
    }
    try testing.expectEqualSlices(Scope, &.{ .session, .today, .days_7, .days_30 }, &Scope.tab_order);
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
