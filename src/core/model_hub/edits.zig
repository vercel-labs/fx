//! The lists a hub action saves: `cycle_order` (D222) and the web search
//! order and exclusions (D223). Pure, so the hub's runtime only persists.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const catalog = @import("catalog.zig");

const Role = model_roles.Role;

/// `cycle` with `role` removed when present, else added at the end.
pub fn toggleCycle(cycle: []const Role, role: Role, out: *[model_roles.role_count]Role) []Role {
    var count: usize = 0;
    var removed = false;
    for (cycle) |item| {
        if (item == role) {
            removed = true;
            continue;
        }
        out[count] = item;
        count += 1;
    }
    if (!removed and count < out.len) {
        out[count] = role;
        count += 1;
    }
    return out[0..count];
}

/// `cycle` with `role` swapped one place earlier or later; unchanged at an end.
pub fn moveCycle(cycle: []const Role, role: Role, later: bool, out: *[model_roles.role_count]Role) []Role {
    const items = out[0..cycle.len];
    @memcpy(items, cycle);
    const index = std.mem.findScalar(Role, items, role) orelse return items;
    if (later and index + 1 < items.len) std.mem.swap(Role, &items[index], &items[index + 1]);
    if (!later and index > 0) std.mem.swap(Role, &items[index], &items[index - 1]);
    return items;
}

pub const max_web_search = 32;

pub const WebSearchLists = struct {
    order_buf: [max_web_search][]const u8 = undefined,
    order_len: usize = 0,
    exclude_buf: [max_web_search][]const u8 = undefined,
    exclude_len: usize = 0,

    pub fn order(self: *const WebSearchLists) []const []const u8 {
        return self.order_buf[0..self.order_len];
    }

    pub fn exclude(self: *const WebSearchLists) []const []const u8 {
        return self.exclude_buf[0..self.exclude_len];
    }
};

pub const WebSearchEdit = union(enum) {
    toggle: usize,
    move: struct { index: usize, later: bool },
};

/// The order to save after `edit`: every provider in the hub's order, so
/// the saved order is exactly what the hub shows, and the excluded ones.
pub fn editWebSearch(rows: []const catalog.WebSearchRow, edit: WebSearchEdit) WebSearchLists {
    var lists: WebSearchLists = .{};
    var order: [max_web_search]usize = undefined;
    const count = @min(rows.len, max_web_search);
    for (order[0..count], 0..) |*slot, index| slot.* = index;
    switch (edit) {
        .move => |move| if (move.index < count) {
            if (move.later and move.index + 1 < count) std.mem.swap(usize, &order[move.index], &order[move.index + 1]);
            if (!move.later and move.index > 0) std.mem.swap(usize, &order[move.index], &order[move.index - 1]);
        },
        .toggle => {},
    }
    for (order[0..count]) |index| {
        lists.order_buf[lists.order_len] = rows[index].id;
        lists.order_len += 1;
        const excluded = switch (edit) {
            .toggle => |toggled| if (toggled == index) !rows[index].excluded else rows[index].excluded,
            .move => rows[index].excluded,
        };
        if (excluded) {
            lists.exclude_buf[lists.exclude_len] = rows[index].id;
            lists.exclude_len += 1;
        }
    }
    return lists;
}

test "cycle toggles append or remove and moves stop at the ends" {
    var buf: [model_roles.role_count]Role = undefined;
    try std.testing.expectEqualSlices(Role, &.{ .deep, .default, .small, .worker }, toggleCycle(&.{ .deep, .default, .small }, .worker, &buf));
    try std.testing.expectEqualSlices(Role, &.{ .deep, .small }, toggleCycle(&.{ .deep, .default, .small }, .default, &buf));
    try std.testing.expectEqualSlices(Role, &.{ .default, .deep, .small }, moveCycle(&.{ .deep, .default, .small }, .deep, true, &buf));
    try std.testing.expectEqualSlices(Role, &.{ .deep, .default, .small }, moveCycle(&.{ .deep, .default, .small }, .deep, false, &buf));
}

test "web search edits save the shown order and the exclusions" {
    const rows = [_]catalog.WebSearchRow{
        .{ .id = "exa", .name = "Exa", .excluded = false, .ready = false },
        .{ .id = "brave", .name = "Brave", .excluded = true, .ready = false },
        .{ .id = "duckduckgo", .name = "DuckDuckGo", .excluded = false, .ready = true },
    };
    const moved = editWebSearch(&rows, .{ .move = .{ .index = 2, .later = false } });
    try std.testing.expectEqual(@as(usize, 3), moved.order().len);
    try std.testing.expectEqualStrings("duckduckgo", moved.order()[1]);
    try std.testing.expectEqualStrings("brave", moved.order()[2]);
    try std.testing.expectEqualStrings("brave", moved.exclude()[0]);
    const toggled = editWebSearch(&rows, .{ .toggle = 1 });
    try std.testing.expectEqual(@as(usize, 0), toggled.exclude().len);
    const off = editWebSearch(&rows, .{ .toggle = 0 });
    try std.testing.expectEqual(@as(usize, 2), off.exclude().len);
}
