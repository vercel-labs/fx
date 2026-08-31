const std = @import("std");
const types = @import("../shared/types.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

const max_model_bytes: usize = 1024;
const max_models: usize = 128;

pub const Scope = enum {
    session,
    hours_24,
    days_7,
    days_30,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .session => "Session",
            .hours_24 => "24 hours",
            .days_7 => "7 days",
            .days_30 => "30 days",
        };
    }

    pub fn cliValue(self: Scope) ?[]const u8 {
        return switch (self) {
            .session => null,
            .hours_24 => "24h",
            .days_7 => "7d",
            .days_30 => "30d",
        };
    }

    fn durationMs(self: Scope) ?i64 {
        return switch (self) {
            .session => null,
            .hours_24 => std.time.ms_per_hour * 24,
            .days_7 => std.time.ms_per_day * 7,
            .days_30 => std.time.ms_per_day * 30,
        };
    }

    pub fn previous(self: Scope) Scope {
        return switch (self) {
            .session => .session,
            .hours_24 => .session,
            .days_7 => .hours_24,
            .days_30 => .days_7,
        };
    }

    pub fn next(self: Scope) Scope {
        return switch (self) {
            .session => .hours_24,
            .hours_24 => .days_7,
            .days_7 => .days_30,
            .days_30 => .days_30,
        };
    }
};

pub fn formatUtcDate(buf: *[24]u8, timestamp_ms: i64) []const u8 {
    if (timestamp_ms < 0) return "Unknown";
    const seconds: u64 = @intCast(@divFloor(timestamp_ms, std.time.ms_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month = switch (month_day.month.numeric()) {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        12 => "Dec",
        else => return "Unknown",
    };
    return std.fmt.bufPrint(
        buf,
        "{s} {d}, {d}",
        .{ month, month_day.day_index + 1, year_day.year },
    ) catch "Unknown";
}

pub const Completeness = enum {
    complete,
    pending,
    incomplete,
    legacy,
};

pub const Coverage = enum {
    not_started,
    partial,
    full,
};

pub const Incident = struct {
    occurred_at_ms: i64,
    completeness: Completeness,
};

pub const PendingMarker = struct {
    id: []u8,
    observed_at_ms: i64,

    pub fn deinit(self: *PendingMarker, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn dupe(self: PendingMarker, alloc: Allocator) Allocator.Error!PendingMarker {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .observed_at_ms = self.observed_at_ms,
        };
    }

    pub fn eql(first: PendingMarker, second: PendingMarker) bool {
        return std.mem.eql(u8, first.id, second.id) and
            first.observed_at_ms == second.observed_at_ms;
    }
};

pub const GenerationFact = struct {
    id: []u8,
    created_at_ms: i64,
    model: []u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64 = 0,
    total_cost: f64,

    pub fn deinit(self: *GenerationFact, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.model);
        self.* = undefined;
    }

    pub fn dupe(self: GenerationFact, alloc: Allocator) Allocator.Error!GenerationFact {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        return .{
            .id = id,
            .created_at_ms = self.created_at_ms,
            .model = try alloc.dupe(u8, self.model),
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = self.reasoning_tokens,
            .billable_web_search_calls = self.billable_web_search_calls,
            .total_cost = self.total_cost,
        };
    }

    pub fn eql(first: GenerationFact, second: GenerationFact) bool {
        return std.mem.eql(u8, first.id, second.id) and
            first.created_at_ms == second.created_at_ms and
            std.mem.eql(u8, first.model, second.model) and
            first.input_tokens == second.input_tokens and
            first.output_tokens == second.output_tokens and
            first.cache_read_tokens == second.cache_read_tokens and
            first.cache_write_tokens == second.cache_write_tokens and
            first.reasoning_tokens == second.reasoning_tokens and
            first.billable_web_search_calls == second.billable_web_search_calls and
            first.total_cost == second.total_cost;
    }
};

pub const ProfileEvent = union(enum) {
    generation: GenerationFact,
    pending: PendingMarker,
    incident: Incident,
};

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
    model: []u8,
    totals: Totals,

    pub fn deinit(self: *ModelUsage, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }
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

pub const SessionModelSource = struct {
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    request_count: ?u64,
};

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
    models: []const SessionModelSource,
    activity: SessionActivity,
};

pub const Snapshot = struct {
    scope: Scope,
    snapshot_time_ms: i64,
    window_start_ms: i64,
    coverage_started_at_ms: ?i64,
    coverage: Coverage,
    completeness: Completeness,
    totals: ?Totals,
    models: []ModelUsage,
    session_activity: ?SessionActivity = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.models) |*model| model.deinit(alloc);
        alloc.free(self.models);
        self.* = undefined;
    }

    pub fn dupe(self: Snapshot, alloc: Allocator) Allocator.Error!Snapshot {
        const models = try alloc.alloc(ModelUsage, self.models.len);
        errdefer alloc.free(models);
        var copied: usize = 0;
        errdefer for (models[0..copied]) |*model| model.deinit(alloc);
        for (self.models, 0..) |model, index| {
            models[index] = .{
                .model = try alloc.dupe(u8, model.model),
                .totals = model.totals,
            };
            copied += 1;
        }
        return .{
            .scope = self.scope,
            .snapshot_time_ms = self.snapshot_time_ms,
            .window_start_ms = self.window_start_ms,
            .coverage_started_at_ms = self.coverage_started_at_ms,
            .coverage = self.coverage,
            .completeness = self.completeness,
            .totals = self.totals,
            .models = models,
            .session_activity = self.session_activity,
        };
    }
};

pub const BuildError = Allocator.Error || error{
    InvalidGenerationFact,
    InvalidSnapshotTime,
    UsageCapacityExceeded,
    UsageOverflow,
};

const MutableTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = 0,
    request_count: u64 = 0,
    total_cost: f64 = 0,

    fn add(self: *MutableTotals, fact: GenerationFact) error{UsageOverflow}!void {
        self.input_tokens = std.math.add(u64, self.input_tokens, fact.input_tokens) catch
            return error.UsageOverflow;
        self.output_tokens = std.math.add(u64, self.output_tokens, fact.output_tokens) catch
            return error.UsageOverflow;
        self.cache_read_tokens = std.math.add(
            u64,
            self.cache_read_tokens,
            fact.cache_read_tokens,
        ) catch return error.UsageOverflow;
        self.cache_write_tokens = std.math.add(
            u64,
            self.cache_write_tokens,
            fact.cache_write_tokens,
        ) catch return error.UsageOverflow;
        self.request_count = std.math.add(u64, self.request_count, 1) catch
            return error.UsageOverflow;
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

    fn freeze(self: MutableTotals, request_count_available: bool) error{UsageOverflow}!Totals {
        return .{
            .total_tokens = std.math.add(
                u64,
                self.input_tokens,
                self.output_tokens,
            ) catch return error.UsageOverflow,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = if (self.request_count == 0)
                null
            else
                self.reasoning_tokens,
            .request_count = if (request_count_available) self.request_count else null,
            .total_cost = self.total_cost,
        };
    }
};

const MutableModel = struct {
    model: []u8,
    totals: MutableTotals = .{},

    fn deinit(self: *MutableModel, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }
};

/// Converts an authoritative session aggregate into the same owned projection
/// used by rolling usage. Session arithmetic is copied, never reconstructed
/// from the model rows.
pub fn buildSessionSnapshot(
    alloc: Allocator,
    source: SessionSource,
) BuildError!Snapshot {
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
        var snapshot = try emptySnapshot(
            alloc,
            .session,
            source.snapshot_time_ms,
            source.session_started_at_ms,
            source.session_started_at_ms,
            .full,
            source.completeness,
        );
        snapshot.session_activity = source.activity;
        return snapshot;
    }
    if (source.models.len > max_models) return error.UsageCapacityExceeded;

    const total_tokens = std.math.add(
        u64,
        source.input_tokens,
        source.output_tokens,
    ) catch return error.UsageOverflow;
    const models = try alloc.alloc(ModelUsage, source.models.len);
    errdefer alloc.free(models);
    var built_models: usize = 0;
    errdefer for (models[0..built_models]) |*model| model.deinit(alloc);
    for (source.models, 0..) |source_model, index| {
        if (source_model.model.len == 0 or
            source_model.model.len > max_model_bytes or
            !std.math.isFinite(source_model.total_cost) or
            source_model.total_cost < 0 or
            source_model.cache_read_tokens > source_model.input_tokens or
            source_model.cache_write_tokens > source_model.input_tokens)
        {
            return error.InvalidGenerationFact;
        }
        if (source_model.reasoning_tokens) |reasoning| {
            if (reasoning > source_model.output_tokens) {
                return error.InvalidGenerationFact;
            }
        }
        for (source_model.model) |byte| {
            if (byte < 0x21 or byte > 0x7e) {
                return error.InvalidGenerationFact;
            }
        }
        models[index] = .{
            .model = try alloc.dupe(u8, source_model.model),
            .totals = .{
                .total_tokens = std.math.add(
                    u64,
                    source_model.input_tokens,
                    source_model.output_tokens,
                ) catch return error.UsageOverflow,
                .input_tokens = source_model.input_tokens,
                .output_tokens = source_model.output_tokens,
                .cache_read_tokens = source_model.cache_read_tokens,
                .cache_write_tokens = source_model.cache_write_tokens,
                .reasoning_tokens = source_model.reasoning_tokens,
                .request_count = source_model.request_count,
                .total_cost = source_model.total_cost,
            },
        };
        built_models += 1;
    }
    sort_utils.sort(ModelUsage, models, {}, modelUsageLessThan);

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
    };
}

pub fn validateFact(fact: GenerationFact) error{InvalidGenerationFact}!void {
    if (!types.validGatewayGenerationId(fact.id) or
        fact.created_at_ms < 0 or
        fact.model.len == 0 or
        fact.model.len > max_model_bytes or
        !std.math.isFinite(fact.total_cost) or
        fact.total_cost < 0 or
        fact.cache_read_tokens > fact.input_tokens or
        fact.cache_write_tokens > fact.input_tokens)
    {
        return error.InvalidGenerationFact;
    }
    if (fact.reasoning_tokens) |reasoning| {
        if (reasoning > fact.output_tokens) return error.InvalidGenerationFact;
    }
    for (fact.model) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidGenerationFact;
    }
}

pub fn validatePendingMarker(
    marker: PendingMarker,
) error{InvalidPendingMarker}!void {
    if (!types.validGatewayGenerationId(marker.id) or marker.observed_at_ms < 0) {
        return error.InvalidPendingMarker;
    }
}

pub fn validateIncident(incident: Incident) error{InvalidUsageIncident}!void {
    if (incident.occurred_at_ms < 0 or
        (incident.completeness != .pending and
            incident.completeness != .incomplete))
    {
        return error.InvalidUsageIncident;
    }
}

/// Builds an owned rolling snapshot from validated facts and an explicit time.
/// The caller must call `Snapshot.deinit`.
pub fn buildRollingSnapshot(
    alloc: Allocator,
    scope: Scope,
    snapshot_time_ms: i64,
    coverage_started_at_ms: ?i64,
    facts: []const GenerationFact,
    incidents: []const Incident,
) BuildError!Snapshot {
    const duration_ms = scope.durationMs() orelse return error.InvalidSnapshotTime;
    if (snapshot_time_ms < 0) return error.InvalidSnapshotTime;
    const window_start_ms = std.math.sub(i64, snapshot_time_ms, duration_ms) catch
        return error.InvalidSnapshotTime;
    var visible_coverage_started_at_ms = coverage_started_at_ms;
    if (coverage_started_at_ms) |started_at_ms| {
        if (started_at_ms < 0) return error.InvalidSnapshotTime;
        if (started_at_ms > snapshot_time_ms) {
            visible_coverage_started_at_ms = null;
        }
    }

    var completeness: Completeness = .complete;
    for (incidents) |incident| {
        if (incident.occurred_at_ms < window_start_ms or
            incident.occurred_at_ms >= snapshot_time_ms)
        {
            continue;
        }
        completeness = switch (incident.completeness) {
            .incomplete, .legacy => .incomplete,
            .pending => if (completeness == .complete) .pending else completeness,
            .complete => completeness,
        };
    }

    const coverage: Coverage = if (visible_coverage_started_at_ms) |started_at_ms|
        if (started_at_ms <= window_start_ms) .full else .partial
    else
        .not_started;
    if (coverage == .not_started) {
        return emptySnapshot(
            alloc,
            scope,
            snapshot_time_ms,
            window_start_ms,
            null,
            .not_started,
            completeness,
        );
    }

    var seen: std.StringHashMapUnmanaged(GenerationFact) = .empty;
    defer seen.deinit(alloc);
    var model_indexes: std.StringHashMapUnmanaged(usize) = .empty;
    defer model_indexes.deinit(alloc);
    var mutable_models: std.ArrayList(MutableModel) = .empty;
    defer {
        for (mutable_models.items) |*model| model.deinit(alloc);
        mutable_models.deinit(alloc);
    }
    var totals: MutableTotals = .{};

    for (facts) |fact| {
        try validateFact(fact);
        if (fact.created_at_ms < window_start_ms or fact.created_at_ms >= snapshot_time_ms) {
            continue;
        }
        const seen_result = try seen.getOrPut(alloc, fact.id);
        if (seen_result.found_existing) {
            if (!GenerationFact.eql(seen_result.value_ptr.*, fact)) {
                completeness = .incomplete;
            }
            continue;
        }
        seen_result.value_ptr.* = fact;

        try totals.add(fact);
        const model_result = try model_indexes.getOrPut(alloc, fact.model);
        if (!model_result.found_existing) {
            if (mutable_models.items.len == max_models) {
                return error.UsageCapacityExceeded;
            }
            const owned_model = try alloc.dupe(u8, fact.model);
            errdefer alloc.free(owned_model);
            try mutable_models.append(alloc, .{ .model = owned_model });
            model_result.value_ptr.* = mutable_models.items.len - 1;
        }
        try mutable_models.items[model_result.value_ptr.*].totals.add(fact);
    }

    const models = try alloc.alloc(ModelUsage, mutable_models.items.len);
    errdefer alloc.free(models);
    var built_models: usize = 0;
    errdefer for (models[0..built_models]) |*model| model.deinit(alloc);
    for (mutable_models.items, 0..) |*model, index| {
        models[index] = .{
            .model = model.model,
            .totals = try model.totals.freeze(true),
        };
        model.model = &.{};
        built_models += 1;
    }
    sort_utils.sort(ModelUsage, models, {}, modelUsageLessThan);

    return .{
        .scope = scope,
        .snapshot_time_ms = snapshot_time_ms,
        .window_start_ms = window_start_ms,
        .coverage_started_at_ms = visible_coverage_started_at_ms,
        .coverage = coverage,
        .completeness = completeness,
        .totals = try totals.freeze(true),
        .models = models,
    };
}

fn emptySnapshot(
    alloc: Allocator,
    scope: Scope,
    snapshot_time_ms: i64,
    window_start_ms: i64,
    coverage_started_at_ms: ?i64,
    coverage: Coverage,
    completeness: Completeness,
) Allocator.Error!Snapshot {
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

fn modelUsageLessThan(_: void, first: ModelUsage, second: ModelUsage) bool {
    if (first.totals.total_tokens != second.totals.total_tokens) {
        return first.totals.total_tokens > second.totals.total_tokens;
    }
    if (first.totals.total_cost != second.totals.total_cost) {
        return first.totals.total_cost > second.totals.total_cost;
    }
    return std.mem.order(u8, first.model, second.model) == .lt;
}

fn testFact(
    id: []u8,
    model: []u8,
    created_at_ms: i64,
    input_tokens: u64,
    output_tokens: u64,
    total_cost: f64,
) GenerationFact {
    return .{
        .id = id,
        .created_at_ms = created_at_ms,
        .model = model,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = 0,
        .total_cost = total_cost,
    };
}

test "rolling snapshots use closed-open boundaries and stable usage-first ordering" {
    const alloc = std.testing.allocator;
    const now = std.time.ms_per_day * 40;
    var facts = [_]GenerationFact{
        testFact(
            @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            @constCast("z/model"),
            now - std.time.ms_per_day * 30,
            3,
            2,
            1,
        ),
        testFact(
            @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"),
            @constCast("b/model"),
            now - 1,
            5,
            5,
            2,
        ),
        testFact(
            @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAX"),
            @constCast("a/model"),
            now - 2,
            5,
            5,
            2,
        ),
        testFact(
            @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAY"),
            @constCast("excluded/model"),
            now,
            100,
            100,
            100,
        ),
    };
    var snapshot = try buildRollingSnapshot(
        alloc,
        .days_30,
        now,
        0,
        &facts,
        &.{},
    );
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(Coverage.full, snapshot.coverage);
    try std.testing.expectEqual(@as(u64, 25), snapshot.totals.?.total_tokens);
    try std.testing.expectEqual(@as(usize, 3), snapshot.models.len);
    try std.testing.expectEqualStrings("a/model", snapshot.models[0].model);
    try std.testing.expectEqualStrings("b/model", snapshot.models[1].model);
    try std.testing.expectEqualStrings("z/model", snapshot.models[2].model);
}

test "rolling snapshots dedupe exact facts and fail closed on conflicts and incidents" {
    const alloc = std.testing.allocator;
    const now = std.time.ms_per_day * 40;
    const original = testFact(
        @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        @constCast("provider/model"),
        now - 1,
        4,
        2,
        0.5,
    );
    const duplicate = original;
    var conflict = original;
    conflict.output_tokens = 3;

    var exact = try buildRollingSnapshot(
        alloc,
        .hours_24,
        now,
        0,
        &.{ original, duplicate },
        &.{},
    );
    defer exact.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 6), exact.totals.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 1), exact.totals.?.request_count.?);

    var conflicted = try buildRollingSnapshot(
        alloc,
        .hours_24,
        now,
        0,
        &.{ original, conflict },
        &.{},
    );
    defer conflicted.deinit(alloc);
    try std.testing.expectEqual(Completeness.incomplete, conflicted.completeness);
    try std.testing.expectEqual(@as(u64, 6), conflicted.totals.?.total_tokens);

    var pending = try buildRollingSnapshot(
        alloc,
        .hours_24,
        now,
        0,
        &.{original},
        &.{.{ .occurred_at_ms = now - 1, .completeness = .pending }},
    );
    defer pending.deinit(alloc);
    try std.testing.expectEqual(Completeness.pending, pending.completeness);
    try std.testing.expectEqual(@as(u64, 6), pending.totals.?.total_tokens);
}

test "rolling snapshots distinguish tracking start from measured zero" {
    const alloc = std.testing.allocator;
    const now = std.time.ms_per_day * 40;
    var unstarted = try buildRollingSnapshot(
        alloc,
        .days_7,
        now,
        null,
        &.{},
        &.{},
    );
    defer unstarted.deinit(alloc);
    try std.testing.expectEqual(Coverage.not_started, unstarted.coverage);
    try std.testing.expectEqual(Completeness.complete, unstarted.completeness);
    try std.testing.expect(unstarted.totals == null);

    var concurrently_started = try buildRollingSnapshot(
        alloc,
        .days_7,
        now,
        now + 1,
        &.{},
        &.{},
    );
    defer concurrently_started.deinit(alloc);
    try std.testing.expectEqual(
        Coverage.not_started,
        concurrently_started.coverage,
    );
    try std.testing.expect(concurrently_started.coverage_started_at_ms == null);
    try std.testing.expect(concurrently_started.totals == null);

    var unknown = try buildRollingSnapshot(
        alloc,
        .days_7,
        now,
        null,
        &.{},
        &.{.{ .occurred_at_ms = now - 1, .completeness = .incomplete }},
    );
    defer unknown.deinit(alloc);
    try std.testing.expectEqual(Coverage.not_started, unknown.coverage);
    try std.testing.expectEqual(Completeness.incomplete, unknown.completeness);
    try std.testing.expect(unknown.totals == null);

    var measured = try buildRollingSnapshot(
        alloc,
        .days_7,
        now,
        now - std.time.ms_per_day,
        &.{},
        &.{},
    );
    defer measured.deinit(alloc);
    try std.testing.expectEqual(Coverage.partial, measured.coverage);
    try std.testing.expectEqual(@as(u64, 0), measured.totals.?.total_tokens);
}

test "non-complete session snapshots preserve known totals and activity" {
    const alloc = std.testing.allocator;
    const activity = SessionActivity{
        .api_duration_complete = true,
        .wall_duration_complete = false,
        .code_complete = true,
        .api_duration_ms = 1200,
        .wall_duration_ms = 3400,
        .lines_added = 5,
        .lines_removed = 2,
    };
    for ([_]Completeness{ .pending, .incomplete }) |completeness| {
        var snapshot = try buildSessionSnapshot(alloc, .{
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
            .activity = activity,
        });
        defer snapshot.deinit(alloc);
        try std.testing.expectEqual(@as(u64, 0), snapshot.totals.?.total_tokens);
        try std.testing.expectEqual(activity, snapshot.session_activity.?);
    }

    var legacy = try buildSessionSnapshot(alloc, .{
        .snapshot_time_ms = 200,
        .session_started_at_ms = 100,
        .completeness = .legacy,
        .total_cost = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .request_count = null,
        .models = &.{},
        .activity = activity,
    });
    defer legacy.deinit(alloc);
    try std.testing.expect(legacy.totals == null);
    try std.testing.expectEqual(activity, legacy.session_activity.?);
}
