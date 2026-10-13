//! What `/usage` shows for one period, built from a cache entry. Pure;
//! mirrors `ViewOf` in the LeanUsage TLA+ model: today's numbers count only
//! when they belong to the current UTC day (`TodayIsToday`).

const std = @import("std");
const report = @import("report.zig");
const cache = @import("cache.zig");

const Allocator = std.mem.Allocator;

pub const Period = enum {
    today,
    days_7,
    /// The calendar month so far, in UTC; matches a monthly budget.
    month,

    pub const all = [_]Period{ .today, .days_7, .month };

    pub fn label(self: Period) []const u8 {
        return switch (self) {
            .today => "today",
            .days_7 => "7d",
            .month => "month",
        };
    }

    pub fn next(self: Period) Period {
        return switch (self) {
            .today => .days_7,
            .days_7 => .month,
            .month => .today,
        };
    }

    pub fn previous(self: Period) Period {
        return switch (self) {
            .today => .month,
            .days_7 => .today,
            .month => .days_7,
        };
    }
};

pub const View = struct {
    arena: std.heap.ArenaAllocator,
    period: Period,
    /// Per-model numbers, highest cost first.
    models: []const report.ModelRow,
    totals: report.Totals,
    /// Whether today's numbers are present for the current UTC day.
    today_current: bool,
    /// For 7d and month: whether the finished days were fetched today.
    finished_current: bool,
    /// When today's numbers were fetched, if any are shown.
    fetched_at_ms: ?i64,
    budget: ?report.Budget,

    pub fn deinit(self: *View) void {
        self.arena.deinit();
    }

    /// Nothing is cached yet for this period.
    pub fn empty(self: View) bool {
        return !self.today_current and (self.period == .today or !self.finished_current) and self.models.len == 0;
    }
};

pub fn build(gpa: Allocator, entry: ?cache.Entry, period: Period, now_ms: i64) Allocator.Error!View {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const day = report.utcDay(now_ms);
    const e = entry orelse cache.Entry{};

    const today: ?cache.Today = if (e.today) |t| (if (t.day == day) t else null) else null;
    const finished: []const report.ModelRow = switch (period) {
        .today => &.{},
        .days_7 => if (e.finished) |f| f.days_7 else &.{},
        .month => if (e.finished) |f| f.month else &.{},
    };

    var merged: std.ArrayList(report.ModelRow) = .empty;
    var totals: report.Totals = .{};
    for ([_][]const report.ModelRow{ finished, if (today) |t| t.models else &.{} }) |part| {
        for (part) |row| {
            totals.add(row.totals);
            if (find(merged.items, row.model)) |existing| {
                existing.totals.add(row.totals);
            } else {
                try merged.append(alloc, .{ .model = try alloc.dupe(u8, row.model), .totals = row.totals });
            }
        }
    }
    std.mem.sort(report.ModelRow, merged.items, {}, costDescending);

    return .{
        .arena = arena,
        .period = period,
        .models = merged.items,
        .totals = totals,
        .today_current = today != null,
        .finished_current = if (e.finished) |f| f.day == day else false,
        .fetched_at_ms = if (today) |t| t.at_ms else null,
        .budget = if (e.budget) |b| b.value else null,
    };
}

fn find(rows: []report.ModelRow, model: []const u8) ?*report.ModelRow {
    for (rows) |*row| if (std.mem.eql(u8, row.model, model)) return row;
    return null;
}

fn costDescending(_: void, a: report.ModelRow, b: report.ModelRow) bool {
    if (a.totals.total_cost != b.totals.total_cost) return a.totals.total_cost > b.totals.total_cost;
    return std.mem.lessThan(u8, a.model, b.model);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const day_ms = std.time.ms_per_day;

fn testRow(model: []const u8, cost: f64, requests: u64) report.ModelRow {
    return .{ .model = model, .totals = .{ .request_count = requests, .total_cost = cost } };
}

test "7d adds today's numbers to the finished days, per model" {
    const now: i64 = 20737 * day_ms + 5 * std.time.ms_per_hour;
    const entry: cache.Entry = .{
        .today = .{ .day = 20737, .at_ms = now - 1000, .models = &.{ testRow("a", 1, 1), testRow("b", 4, 2) } },
        .finished = .{ .day = 20737, .at_ms = now - 1000, .days_7 = &.{testRow("a", 10, 5)}, .month = &.{testRow("a", 30, 9)} },
        .budget = .{ .at_ms = now, .value = .{ .limit = 100, .spent = 41, .period = .monthly } },
    };
    var week = try build(testing.allocator, entry, .days_7, now);
    defer week.deinit();
    try testing.expectEqual(@as(usize, 2), week.models.len);
    try testing.expectEqualStrings("a", week.models[0].model);
    try testing.expectEqual(@as(f64, 11), week.models[0].totals.total_cost);
    try testing.expectEqual(@as(u64, 8), week.totals.request_count);
    try testing.expect(week.today_current and week.finished_current);
    try testing.expectEqual(@as(f64, 41), week.budget.?.spent);

    var day = try build(testing.allocator, entry, .today, now);
    defer day.deinit();
    try testing.expectEqual(@as(f64, 5), day.totals.total_cost);
}

test "after midnight yesterday's numbers are not shown as today" {
    const yesterday: i64 = 20736 * day_ms + 23 * std.time.ms_per_hour;
    const entry: cache.Entry = .{
        .today = .{ .day = 20736, .at_ms = yesterday, .models = &.{testRow("a", 9, 3)} },
        .finished = .{ .day = 20736, .at_ms = yesterday, .days_7 = &.{testRow("a", 1, 1)}, .month = &.{testRow("a", 2, 1)} },
    };
    const just_after: i64 = 20737 * day_ms + 1000;
    var today = try build(testing.allocator, entry, .today, just_after);
    defer today.deinit();
    try testing.expect(!today.today_current);
    try testing.expectEqual(@as(usize, 0), today.models.len);
    try testing.expect(today.empty());
    var week = try build(testing.allocator, entry, .days_7, just_after);
    defer week.deinit();
    try testing.expect(!week.finished_current);
    try testing.expectEqual(@as(f64, 1), week.totals.total_cost);
}

test "periods cycle both ways" {
    try testing.expectEqual(Period.days_7, Period.today.next());
    try testing.expectEqual(Period.today, Period.month.next());
    try testing.expectEqual(Period.month, Period.today.previous());
}
