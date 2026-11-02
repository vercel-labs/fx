//! Navigation state of the `/usage` dashboard. The numbers come from
//! `usage.Dashboard`; this only remembers which period the model table
//! lists, the selected model, and whether its detail screen is open.

const std = @import("std");
const usage = @import("../../usage/usage.zig");

pub const State = struct {
    active: bool = false,
    /// The period the model table lists. Kept across opens.
    period: usage.Period = .month,
    selected_model: usize = 0,
    model_window_start: usize = 0,
    /// Whether the selected model's detail screen is open.
    detail: bool = false,
    snapshot: ?usage.Snapshot = null,
    /// The dashboard generation `snapshot` was built from.
    generation: u64 = 0,

    /// Takes ownership of `snapshot`.
    pub fn open(self: *State, snapshot: usage.Snapshot, generation: u64) void {
        if (self.snapshot) |*old| old.deinit();
        self.* = .{
            .active = true,
            .period = self.period,
            .snapshot = snapshot,
            .generation = generation,
        };
    }

    /// Replaces the snapshot, keeping the selected model by name when it is
    /// still listed. Takes ownership of `snapshot`.
    pub fn replace(self: *State, snapshot: usage.Snapshot, generation: u64) void {
        const old_selected = self.selectedModelName();
        const models = snapshot.of(self.period).models;
        const found = findModel(models, old_selected);
        const selected = found orelse @min(self.selected_model, models.len -| 1);
        // Codex has no selection; its list keeps its scroll position.
        const keeps_scroll = snapshot.scope == .codex;
        // Look the name up before the old snapshot is freed.
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = snapshot;
        self.generation = generation;
        self.selected_model = selected;
        if (!keeps_scroll) self.model_window_start = @min(self.model_window_start, selected);
        // A detail screen whose model left the list goes back to the table.
        if (found == null) self.detail = false;
    }

    pub fn close(self: *State) void {
        if (self.snapshot) |*old| old.deinit();
        self.* = .{ .period = self.period };
    }

    /// Lists `period` in the model table. Each period lists other models,
    /// so the selection starts over. Returns whether anything changed.
    pub fn setPeriod(self: *State, period: usage.Period) bool {
        if (!self.active or self.detail or period == self.period) return false;
        self.period = period;
        self.selected_model = 0;
        self.model_window_start = 0;
        return true;
    }

    /// ↑↓ in the table or on a detail screen (the next model's details).
    /// The Codex list has no selection, so ↑↓ scrolls it.
    pub fn moveModel(self: *State, delta: i32, visible_model_rows: usize) bool {
        if (!self.active or delta == 0) return false;
        if (self.snapshot) |*s| if (s.scope == .codex) return self.scrollCodex(s, delta, visible_model_rows);
        const models = self.listedModels();
        if (models.len == 0) return false;
        const next = if (delta > 0)
            @min(self.selected_model +| 1, models.len - 1)
        else
            self.selected_model -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepSelectionVisible(visible_model_rows);
        return true;
    }

    /// Enter: the selected model's detail screen.
    pub fn openDetail(self: *State) bool {
        if (!self.active or self.detail or self.listedModels().len == 0) return false;
        self.detail = true;
        return true;
    }

    /// Esc on a detail screen: back to the table.
    pub fn closeDetail(self: *State) bool {
        if (!self.detail) return false;
        self.detail = false;
        return true;
    }

    pub fn listedModels(self: *const State) []const usage.report.ModelRow {
        return if (self.snapshot) |*s| s.of(self.period).models else &.{};
    }

    pub fn selectedModelName(self: *const State) ?[]const u8 {
        const list = self.listedModels();
        return if (self.selected_model < list.len) list[self.selected_model].model else null;
    }

    fn scrollCodex(self: *State, snapshot: *const usage.Snapshot, delta: i32, visible_model_rows: usize) bool {
        var buf: [usage.codex.max_shares]usage.codex.Share = undefined;
        const total = snapshot.codexModelShares(self.period, &buf).len;
        const last_start = total -| @max(visible_model_rows, 1);
        const start = @min(self.model_window_start, last_start);
        const next = if (delta > 0) @min(start +| 1, last_start) else start -| 1;
        if (next == self.model_window_start) return false;
        self.model_window_start = next;
        return true;
    }

    fn keepSelectionVisible(self: *State, visible_model_rows: usize) void {
        const visible = @max(visible_model_rows, 1);
        if (self.selected_model < self.model_window_start) {
            self.model_window_start = self.selected_model;
        } else if (self.selected_model >= self.model_window_start +| visible) {
            self.model_window_start = self.selected_model - (visible - 1);
        }
    }
};

fn findModel(models: []const usage.report.ModelRow, target: ?[]const u8) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}

/// A snapshot whose every period lists `names`, highest cost first.
fn testSnapshot(names: []const []const u8) !usage.Snapshot {
    const alloc = std.testing.allocator;
    var views: [usage.Period.all.len]usage.View = undefined;
    for (usage.Period.all, 0..) |period, p| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const rows = try arena.allocator().alloc(usage.report.ModelRow, names.len);
        for (rows, names, 0..) |*row, name, i| {
            row.* = .{ .model = try arena.allocator().dupe(u8, name), .totals = .{ .total_cost = @floatFromInt(10 - i) } };
        }
        views[p] = .{
            .arena = arena,
            .period = period,
            .models = rows,
            .totals = .{},
            .today_current = true,
            .finished_current = true,
            .fetched_at_ms = 0,
            .budget = null,
        };
    }
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .views = views,
        .status = .ready,
        .label = "",
        .now_ms = 0,
    };
}

test "a refresh keeps the selected model by name" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "a", "b", "c" }), 1);
    try std.testing.expectEqual(usage.Period.month, state.period);
    try std.testing.expect(state.moveModel(1, 5));
    try std.testing.expect(state.openDetail());
    state.replace(try testSnapshot(&.{ "c", "b" }), 2);
    try std.testing.expectEqual(@as(usize, 1), state.selected_model);
    try std.testing.expect(state.detail);
    // The detail screen's model left the list: back to the table.
    state.replace(try testSnapshot(&.{"z"}), 3);
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    try std.testing.expect(!state.detail);
}

test "Tab changes the listed period only from the table" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "a", "b" }), 1);
    _ = state.moveModel(1, 5);
    try std.testing.expect(state.setPeriod(.today));
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    try std.testing.expect(!state.setPeriod(.today));
    try std.testing.expect(state.openDetail());
    try std.testing.expect(!state.setPeriod(.days_7));
    try std.testing.expect(state.closeDetail());
    try std.testing.expect(!state.closeDetail());
    state.close();
    // The period survives closing and reopening.
    state.open(try testSnapshot(&.{"a"}), 2);
    try std.testing.expectEqual(usage.Period.today, state.period);
}

/// A Codex snapshot whose month lists five models, largest first.
fn codexTestSnapshot() !usage.Snapshot {
    var snapshot = try testSnapshot(&.{});
    snapshot.scope = .codex;
    snapshot.codex_usage = .{ .plan = "plus", .breakdown = .{ .days = &.{.{ .day = 0, .models = &.{
        .{ .model = "a", .speed = "fast", .value = 5 },
        .{ .model = "b", .speed = "fast", .value = 4 },
        .{ .model = "c", .speed = "fast", .value = 3 },
        .{ .model = "d", .speed = "fast", .value = 2 },
        .{ .model = "e", .speed = "fast", .value = 1 },
    } }} } };
    return snapshot;
}

test "the Codex model list scrolls with ↑↓ and keeps its place on refresh" {
    var state: State = .{};
    defer state.close();
    state.open(try codexTestSnapshot(), 1);
    // Three of five rows fit: the window moves down twice, then stops.
    try std.testing.expect(state.moveModel(1, 3));
    try std.testing.expect(state.moveModel(1, 3));
    try std.testing.expect(!state.moveModel(1, 3));
    try std.testing.expectEqual(@as(usize, 2), state.model_window_start);
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    // A refresh keeps the scroll position.
    state.replace(try codexTestSnapshot(), 2);
    try std.testing.expectEqual(@as(usize, 2), state.model_window_start);
    try std.testing.expect(state.moveModel(-1, 3));
    try std.testing.expect(state.moveModel(-1, 3));
    try std.testing.expect(!state.moveModel(-1, 3));
    // A list that fits does not scroll, and Enter opens nothing.
    try std.testing.expect(!state.moveModel(1, 5));
    try std.testing.expect(!state.openDetail());
}

test "selection stays inside the visible model rows" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "a", "b", "c", "d" }), 1);
    _ = state.moveModel(1, 2);
    _ = state.moveModel(1, 2);
    try std.testing.expectEqual(@as(usize, 2), state.selected_model);
    try std.testing.expectEqual(@as(usize, 1), state.model_window_start);
    try std.testing.expect(!state.moveModel(1, 2) or state.selected_model == 3);
    state.close();
    try std.testing.expect(!state.active);
    try std.testing.expect(!state.moveModel(1, 2));
    try std.testing.expect(!state.openDetail());
}
