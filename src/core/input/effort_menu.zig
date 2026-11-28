//! State of the `/effort` menu: the reasoning effort levels the current
//! model offers, the one in use, and the one highlighted. The composer text
//! filters the levels, as it filters the `/model` menu's models.

const std = @import("std");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// `default`, then every level a model can declare.
pub const max_options = types.ReasoningEffort.max_options + 1;

/// Writes the levels of `levels` whose label matches `query` to `out`, in
/// their order, and returns how many. The `/effort` menu and the `/effort `
/// column both filter with it, so a query lists the same levels in each.
pub fn filterLevels(
    levels: []const types.ReasoningEffort,
    query: []const u8,
    out: *[max_options]types.ReasoningEffort,
) usize {
    const count = @min(levels.len, max_options);
    // A named level keeps its label inline, so each label slices into
    // `levels`, which outlives the filter.
    var labels: [max_options][]const u8 = undefined;
    for (levels[0..count], labels[0..count]) |*level, *label| label.* = level.displayLabel();
    const kept: fuzzy_match.Filter(fuzzy_match.LabelMatches) = .init(.{ .labels = labels[0..count], .query = query }, count);
    var kept_count: usize = 0;
    for (levels[0..count], 0..) |level, i| {
        if (!kept.keeps(i)) continue;
        out[kept_count] = level;
        kept_count += 1;
    }
    return kept_count;
}

/// Call `close` with the allocator passed to `open`.
pub const State = struct {
    active: bool = false,
    /// The model whose levels the menu lists.
    model: std.ArrayList(u8) = .empty,
    /// `default`, then the model's levels in the order it declares them.
    options: [max_options]types.ReasoningEffort = undefined,
    option_count: usize = 0,
    /// The level in use when the menu opened.
    in_use: types.ReasoningEffort = .auto,
    /// The options that match the query, in their order.
    shown: [max_options]types.ReasoningEffort = @splat(.auto),
    shown_count: usize = 0,
    /// Index of `in_use` in `shown`, or null when the query leaves it out.
    current: ?usize = null,
    /// Index of the highlighted level in `shown`.
    selected: usize = 0,
    /// The first level shown when they do not all fit.
    window_start: usize = 0,

    /// Opens the menu on `model`'s levels with `current` highlighted. A level
    /// the model does not offer highlights `default`. Leaves the state as it
    /// was when the copy of `model` fails.
    pub fn open(
        self: *State,
        alloc: Allocator,
        model: []const u8,
        capabilities: model_capabilities.Capabilities,
        current: types.ReasoningEffort,
    ) Allocator.Error!void {
        try self.model.ensureTotalCapacity(alloc, model.len);
        self.model.clearRetainingCapacity();
        self.model.appendSliceAssumeCapacity(model);
        const declared = capabilities.reasoning_efforts.slice();
        const count = @min(declared.len, max_options - 1);
        self.options[0] = .auto;
        @memcpy(self.options[1 .. count + 1], declared[0..count]);
        self.option_count = count + 1;
        self.in_use = self.options[@min(model_capabilities.reasoningEffortIndex(capabilities, current), count)];
        self.active = true;
        self.setQuery("");
    }

    /// Lists the levels that match `query`. A query highlights the first
    /// match, and an empty one the level in use, as when the menu opened.
    pub fn setQuery(self: *State, query: []const u8) void {
        if (!self.active) return;
        const trimmed = std.mem.trim(u8, query, " \t");
        self.shown_count = filterLevels(self.options[0..self.option_count], trimmed, &self.shown);
        self.current = for (self.shown[0..self.shown_count], 0..) |level, i| {
            if (level.eql(self.in_use)) break i;
        } else null;
        self.selected = if (trimmed.len == 0) self.current orelse 0 else 0;
        self.window_start = 0;
    }

    /// Moves the highlight, wrapping past the first and the last level as
    /// the `/model` menu does.
    pub fn move(self: *State, delta: i32) void {
        if (!self.active or self.shown_count == 0) return;
        const count: i64 = @intCast(self.shown_count);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
    }

    /// The highlighted level, or null when the menu is closed or no level
    /// matches the query.
    pub fn selectedEffort(self: *const State) ?types.ReasoningEffort {
        if (!self.active or self.shown_count == 0) return null;
        return self.shown[self.selected];
    }

    /// The levels that match the query.
    pub fn levels(self: *const State) []const types.ReasoningEffort {
        return self.shown[0..self.shown_count];
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.model.deinit(alloc);
        self.* = .{};
    }
};

const low = types.ReasoningEffort.literal("low");
const medium = types.ReasoningEffort.literal("medium");
const high = types.ReasoningEffort.literal("high");
const xhigh = types.ReasoningEffort.literal("xhigh");

fn testCapabilities() model_capabilities.Capabilities {
    return .{ .reasoning_efforts = .fromSlice(&.{ low, medium, high, xhigh }) };
}

fn expectLevels(expected: []const types.ReasoningEffort, menu: *const State) !void {
    try std.testing.expectEqual(expected.len, menu.levels().len);
    for (expected, menu.levels()) |want, got| try std.testing.expect(want.eql(got));
}

fn expectSelected(expected: ?types.ReasoningEffort, menu: *const State) !void {
    const got = menu.selectedEffort();
    if (expected) |want| {
        try std.testing.expect(got != null and want.eql(got.?));
    } else {
        try std.testing.expect(got == null);
    }
}

test "a query lists the matching levels in their order and highlights the first" {
    var menu: State = .{};
    defer menu.close(std.testing.allocator);
    try menu.open(std.testing.allocator, "acme/thinker", testCapabilities(), medium);
    try expectLevels(&.{ .auto, low, medium, high, xhigh }, &menu);
    try std.testing.expectEqual(@as(?usize, 2), menu.current);
    try expectSelected(medium, &menu);

    menu.setQuery("h");
    try expectLevels(&.{ high, xhigh }, &menu);
    try std.testing.expectEqual(@as(?usize, null), menu.current);
    try expectSelected(high, &menu);
    menu.move(1);
    try expectSelected(xhigh, &menu);
    menu.move(1);
    try expectSelected(high, &menu);

    // `default` is the label of `.auto`, so the query matches the label.
    menu.setQuery(" def ");
    try expectLevels(&.{.auto}, &menu);
}

test "a query with no match leaves nothing to apply, and an empty one highlights the level in use again" {
    var menu: State = .{};
    defer menu.close(std.testing.allocator);
    try menu.open(std.testing.allocator, "acme/thinker", testCapabilities(), high);
    menu.setQuery("zz");
    try std.testing.expectEqual(@as(usize, 0), menu.levels().len);
    try expectSelected(null, &menu);
    menu.move(1);
    try expectSelected(null, &menu);

    menu.setQuery("");
    try std.testing.expectEqual(@as(usize, 5), menu.levels().len);
    try std.testing.expectEqual(@as(?usize, 3), menu.current);
    try expectSelected(high, &menu);
}

test "a closed menu ignores a query" {
    var menu: State = .{};
    menu.setQuery("h");
    try std.testing.expectEqual(@as(usize, 0), menu.levels().len);
    try expectSelected(null, &menu);
}
