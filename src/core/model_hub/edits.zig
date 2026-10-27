//! The lists a hub action saves: `cycle_order` (D222), the web search
//! order and exclusions (D223), and a role's chain (D250). Pure, so the
//! hub's runtime only persists.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const catalog = @import("catalog.zig");
const types = @import("../shared/types.zig");

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

/// A role chain change with the new model's reference spelled out.
pub const ChainEdit = union(enum) {
    put: struct { entry: ?usize, ref: []const u8 },
    remove: usize,
    move: struct { entry: usize, later: bool },
    thinking: struct { entry: usize, effort: ?types.ReasoningEffort },
};

/// The role's settings value after `edit`: its references joined by `, `,
/// each with its level, or null when the chain is now empty. A model put
/// into the chain drops any other copy of it, and is saved without a
/// level, as proto saves new picks. Caller owns the bytes.
pub fn editRoleChain(alloc: std.mem.Allocator, entries: []const catalog.EntryRow, edit: ChainEdit) !?[]u8 {
    var chain: model_roles.Chain = .{};
    for (entries[0..@min(entries.len, model_roles.max_chain)]) |entry| {
        chain.items[chain.len] = .{ .ref = entry.ref, .effort = entry.effort };
        chain.len += 1;
    }
    switch (edit) {
        .put => |put| put: {
            // Adding a model the chain already has changes nothing, as in proto.
            if (put.entry == null) for (chain.entries()) |entry| {
                if (std.mem.eql(u8, entry.ref, put.ref)) break :put;
            };
            const at = put.entry orelse chain.len;
            const fresh: model_roles.Entry = .{ .ref = put.ref };
            if (at < chain.len) {
                chain.items[at] = fresh;
            } else if (chain.len < model_roles.max_chain) {
                chain.items[chain.len] = fresh;
                chain.len += 1;
            }
            const kept = @min(at, chain.len - 1);
            var index = chain.len;
            while (index > 0) {
                index -= 1;
                if (index != kept and std.mem.eql(u8, chain.items[index].ref, put.ref)) removeAt(&chain, index);
            }
        },
        .remove => |at| if (at < chain.len) removeAt(&chain, at),
        .move => |move| if (move.entry < chain.len) {
            if (move.later and move.entry + 1 < chain.len) std.mem.swap(model_roles.Entry, &chain.items[move.entry], &chain.items[move.entry + 1]);
            if (!move.later and move.entry > 0) std.mem.swap(model_roles.Entry, &chain.items[move.entry], &chain.items[move.entry - 1]);
        },
        .thinking => |thinking| if (thinking.entry < chain.len) {
            chain.items[thinking.entry].effort = thinking.effort;
        },
    }
    if (chain.len == 0) return null;
    return try chain.joinAlloc(alloc);
}

fn removeAt(chain: *model_roles.Chain, at: usize) void {
    var index = at;
    while (index + 1 < chain.len) : (index += 1) chain.items[index] = chain.items[index + 1];
    chain.len -= 1;
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

test "role chain edits put, dedupe, reorder, set levels and empty out" {
    const alloc = std.testing.allocator;
    const entries = [_]catalog.EntryRow{
        .{ .ref = "codex/gpt-5.6-luna", .shown = "", .effort = types.ReasoningEffort.literal("low") },
        .{ .ref = "cento/claude-cento-lite", .shown = "" },
    };
    const Case = struct { edit: ChainEdit, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .edit = .{ .put = .{ .entry = null, .ref = "cento/claude-cento" } }, .want = "codex/gpt-5.6-luna:low, cento/claude-cento-lite, cento/claude-cento" },
        // Putting a model already in the chain moves it there.
        .{ .edit = .{ .put = .{ .entry = 0, .ref = "cento/claude-cento-lite" } }, .want = "cento/claude-cento-lite" },
        .{ .edit = .{ .put = .{ .entry = null, .ref = "codex/gpt-5.6-luna" } }, .want = "codex/gpt-5.6-luna:low, cento/claude-cento-lite" },
        .{ .edit = .{ .move = .{ .entry = 1, .later = false } }, .want = "cento/claude-cento-lite, codex/gpt-5.6-luna:low" },
        .{ .edit = .{ .move = .{ .entry = 1, .later = true } }, .want = "codex/gpt-5.6-luna:low, cento/claude-cento-lite" },
        .{ .edit = .{ .remove = 0 }, .want = "cento/claude-cento-lite" },
        .{ .edit = .{ .thinking = .{ .entry = 1, .effort = types.ReasoningEffort.literal("high") } }, .want = "codex/gpt-5.6-luna:low, cento/claude-cento-lite:high" },
        .{ .edit = .{ .thinking = .{ .entry = 0, .effort = null } }, .want = "codex/gpt-5.6-luna, cento/claude-cento-lite" },
    };
    for (cases) |case| {
        const got = try editRoleChain(alloc, &entries, case.edit);
        defer if (got) |bytes| alloc.free(bytes);
        try std.testing.expectEqualStrings(case.want.?, got.?);
    }
    try std.testing.expect(try editRoleChain(alloc, entries[0..1], .{ .remove = 0 }) == null);
    const fresh = (try editRoleChain(alloc, &.{}, .{ .put = .{ .entry = null, .ref = "cento/x" } })).?;
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings("cento/x", fresh);
}
