//! Navigation state of the `/usage` dashboard. The numbers come from
//! `usage.Dashboard`; this only remembers which period the model table
//! lists, the selected model, and whether its detail screen is open.

const std = @import("std");
const usage = @import("../../usage/usage.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const list_window = @import("../shared/list_window.zig");

pub const ModelMatches = struct {
    models: []const usage.report.ModelRow,
    query: []const u8,

    pub fn matchAt(self: ModelMatches, position: usize) ?fuzzy_match.Match {
        return fuzzy_match.match(self.query, &.{.{ .text = self.models[position].model }});
    }
};

pub fn modelFilter(models: []const usage.report.ModelRow, query: []const u8) fuzzy_match.Filter(ModelMatches) {
    return .init(.{ .models = models, .query = query }, models.len);
}

pub const ShareMatches = struct {
    shares: []const usage.codex.Share,
    query: []const u8,

    pub fn matchAt(self: ShareMatches, position: usize) ?fuzzy_match.Match {
        return fuzzy_match.match(self.query, &.{.{ .text = self.shares[position].name }});
    }
};

pub fn codexModelFilter(shares: []const usage.codex.Share, query: []const u8) fuzzy_match.Filter(ShareMatches) {
    return .init(.{ .shares = shares, .query = query }, shares.len);
}

pub const ProductMatches = struct {
    products: []const usage.grok.Product,
    query: []const u8,

    pub fn matchAt(self: ProductMatches, position: usize) ?fuzzy_match.Match {
        return fuzzy_match.match(self.query, &.{.{ .text = self.products[position].name }});
    }
};

pub fn grokProductFilter(products: []const usage.grok.Product, query: []const u8) fuzzy_match.Filter(ProductMatches) {
    return .init(.{ .products = products, .query = query }, products.len);
}

pub fn filteredCodexShares(
    snapshot: *const usage.Snapshot,
    period: usage.Period,
    query: []const u8,
    buf: *[usage.codex.max_shares]usage.codex.Share,
) []usage.codex.Share {
    var raw_buf: [usage.codex.max_shares]usage.codex.Share = undefined;
    const raw = snapshot.codexModelShares(period, &raw_buf);
    const filter = codexModelFilter(raw, query);
    var count: usize = 0;
    for (0..raw.len) |i| {
        if (!filter.keeps(i)) continue;
        buf[count] = raw[i];
        count += 1;
    }
    return buf[0..count];
}

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
    /// still listed under `query`. Takes ownership of `snapshot`.
    pub fn replace(self: *State, snapshot: usage.Snapshot, generation: u64, query: []const u8) void {
        const old_selected = self.selectedModelName(query);
        const models = snapshot.of(self.period).models;
        const filter = modelFilter(models, query);
        const count = filter.count();
        const found = findFilteredModel(models, filter, old_selected);
        const selected = found orelse @min(self.selected_model, count -| 1);
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

    pub fn resetForQuery(self: *State) void {
        if (!self.active) return;
        self.detail = false;
        self.selected_model = 0;
        self.model_window_start = 0;
    }

    /// Restores the selection in the unfiltered list when Esc clears the query,
    /// so an open detail screen stays on the same model.
    pub fn preserveSelectionAfterQueryClear(self: *State, prev_name: ?[]const u8) void {
        if (!self.active) return;
        const models = self.listedModels();
        const selected = findModel(models, prev_name) orelse 0;
        self.selected_model = selected;
        self.model_window_start = @min(self.model_window_start, selected);
    }

    /// ↑↓ in the table or on a detail screen (the next model's details).
    /// The Codex list has no selection, so ↑↓ scrolls it.
    pub fn moveModel(self: *State, delta: i32, visible_model_rows: usize, query: []const u8) bool {
        if (!self.active or delta == 0) return false;
        if (self.snapshot) |*s| if (s.scope == .codex) return self.scrollCodex(s, delta, visible_model_rows, query);
        const count = self.filteredModelCount(query);
        if (count == 0) return false;
        const clamped = @min(self.selected_model, count - 1);
        const next = if (delta > 0)
            @min(clamped +| 1, count - 1)
        else
            clamped -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepSelectionVisible(count, visible_model_rows);
        return true;
    }

    /// Enter: the selected model's detail screen.
    pub fn openDetail(self: *State, query: []const u8) bool {
        if (!self.active or self.detail or self.filteredModelCount(query) == 0) return false;
        const count = self.filteredModelCount(query);
        self.selected_model = @min(self.selected_model, count - 1);
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

    pub fn filteredModelCount(self: *const State, query: []const u8) usize {
        return modelFilter(self.listedModels(), query).count();
    }

    pub fn filteredModelAt(self: *const State, query: []const u8, display_index: usize) ?usage.report.ModelRow {
        const models = self.listedModels();
        const raw_index = modelFilter(models, query).at(display_index) orelse return null;
        return models[raw_index];
    }

    pub fn selectedModelName(self: *const State, query: []const u8) ?[]const u8 {
        const count = self.filteredModelCount(query);
        if (count == 0) return null;
        const model = self.filteredModelAt(query, @min(self.selected_model, count - 1)) orelse return null;
        return model.model;
    }

    fn scrollCodex(self: *State, snapshot: *const usage.Snapshot, delta: i32, visible_model_rows: usize, query: []const u8) bool {
        var buf: [usage.codex.max_shares]usage.codex.Share = undefined;
        const total = filteredCodexShares(snapshot, self.period, query, &buf).len;
        const last_start = total -| @max(visible_model_rows, 1);
        const start = @min(self.model_window_start, last_start);
        const next = if (delta > 0) @min(start +| 1, last_start) else start -| 1;
        if (next == self.model_window_start) return false;
        self.model_window_start = next;
        return true;
    }

    fn keepSelectionVisible(self: *State, count: usize, visible_model_rows: usize) void {
        const visible: u16 = @intCast(@min(@max(visible_model_rows, 1), std.math.maxInt(u16)));
        self.model_window_start = list_window.updateEdgeStart(self.model_window_start, count, self.selected_model, visible);
    }
};

fn findModel(models: []const usage.report.ModelRow, target: ?[]const u8) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}

fn findFilteredModel(
    models: []const usage.report.ModelRow,
    filter: fuzzy_match.Filter(ModelMatches),
    target: ?[]const u8,
) ?usize {
    const name = target orelse return null;
    var display_index: usize = 0;
    for (models, 0..) |model, raw_index| {
        if (!filter.keeps(raw_index)) continue;
        if (std.mem.eql(u8, model.model, name)) return display_index;
        display_index += 1;
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
    try std.testing.expect(state.moveModel(1, 5, ""));
    try std.testing.expect(state.openDetail(""));
    state.replace(try testSnapshot(&.{ "c", "b" }), 2, "");
    try std.testing.expectEqual(@as(usize, 1), state.selected_model);
    try std.testing.expect(state.detail);
    // The detail screen's model left the list: back to the table.
    state.replace(try testSnapshot(&.{"z"}), 3, "");
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    try std.testing.expect(!state.detail);
}

test "Tab changes the listed period only from the table" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "a", "b" }), 1);
    _ = state.moveModel(1, 5, "");
    try std.testing.expect(state.setPeriod(.today));
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    try std.testing.expect(!state.setPeriod(.today));
    try std.testing.expect(state.openDetail(""));
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
    try std.testing.expect(state.moveModel(1, 3, ""));
    try std.testing.expect(state.moveModel(1, 3, ""));
    try std.testing.expect(!state.moveModel(1, 3, ""));
    try std.testing.expectEqual(@as(usize, 2), state.model_window_start);
    try std.testing.expectEqual(@as(usize, 0), state.selected_model);
    // A refresh keeps the scroll position.
    state.replace(try codexTestSnapshot(), 2, "");
    try std.testing.expectEqual(@as(usize, 2), state.model_window_start);
    try std.testing.expect(state.moveModel(-1, 3, ""));
    try std.testing.expect(state.moveModel(-1, 3, ""));
    try std.testing.expect(!state.moveModel(-1, 3, ""));
    // A list that fits does not scroll, and Enter opens nothing.
    try std.testing.expect(!state.moveModel(1, 5, ""));
    try std.testing.expect(!state.openDetail(""));
}

test "selection stays inside the visible model rows" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "a", "b", "c", "d" }), 1);
    _ = state.moveModel(1, 2, "");
    _ = state.moveModel(1, 2, "");
    try std.testing.expectEqual(@as(usize, 2), state.selected_model);
    try std.testing.expectEqual(@as(usize, 1), state.model_window_start);
    try std.testing.expect(!state.moveModel(1, 2, "") or state.selected_model == 3);
    state.close();
    try std.testing.expect(!state.active);
    try std.testing.expect(!state.moveModel(1, 2, ""));
    try std.testing.expect(!state.openDetail(""));
}

test "fuzzy filter covers AI Gateway models, Codex models, and Grok products and preserves selection across query clear" {
    var state: State = .{};
    defer state.close();
    state.open(try testSnapshot(&.{ "anthropic/claude-opus-4-6", "openai/gpt-5", "anthropic/claude-sonnet-4-5" }), 1);
    try std.testing.expectEqual(@as(usize, 3), state.filteredModelCount("op"));
    try std.testing.expectEqualStrings("anthropic/claude-opus-4-6", state.filteredModelAt("op", 0).?.model);
    try std.testing.expectEqualStrings("openai/gpt-5", state.filteredModelAt("op", 1).?.model);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-5", state.filteredModelAt("op", 2).?.model);
    try std.testing.expect(state.moveModel(1, 5, "op"));
    try std.testing.expect(state.moveModel(1, 5, "op"));
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-5", state.selectedModelName("op").?);
    try std.testing.expect(state.openDetail("op"));

    // Clearing the query preserves the selected model in detail view.
    const prev_name = state.selectedModelName("op");
    state.preserveSelectionAfterQueryClear(prev_name);
    try std.testing.expect(state.detail);
    try std.testing.expectEqual(@as(usize, 2), state.selected_model);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-5", state.selectedModelName("").?);

    // Empty filter blocks openDetail and clamps moveModel.
    try std.testing.expect(state.closeDetail());
    state.resetForQuery();
    try std.testing.expectEqual(@as(usize, 0), state.filteredModelCount("zzz"));
    try std.testing.expect(!state.moveModel(1, 5, "zzz"));
    try std.testing.expect(!state.openDetail("zzz"));

    // Codex filtering.
    var codex_state: State = .{};
    defer codex_state.close();
    var codex = try testSnapshot(&.{});
    codex.scope = .codex;
    codex.codex_usage = .{ .plan = "plus", .breakdown = .{ .days = &.{.{ .day = 0, .models = &.{
        .{ .model = "gpt-6-astra", .speed = "fast", .value = 5 },
        .{ .model = "gpt-6.1-sol", .speed = "standard", .value = 4 },
        .{ .model = "gpt-5.6-luna", .speed = "fast", .value = 3 },
    } }} } };
    codex_state.open(codex, 1);
    var share_buf: [usage.codex.max_shares]usage.codex.Share = undefined;
    const filtered_shares = filteredCodexShares(&codex_state.snapshot.?, .month, "sol", &share_buf);
    try std.testing.expectEqual(@as(usize, 1), filtered_shares.len);
    try std.testing.expectEqualStrings("gpt-6.1-sol", filtered_shares[0].name);

    // Grok product filtering.
    const grok_products = [_]usage.grok.Product{
        .{ .name = "grok build", .used_percent = 61.2 },
        .{ .name = "chat", .used_percent = 3.0 },
    };
    const grok_filter = grokProductFilter(&grok_products, "build");
    try std.testing.expectEqual(@as(usize, 1), grok_filter.count());
    try std.testing.expectEqualStrings("grok build", grok_products[grok_filter.at(0).?].name);
}
