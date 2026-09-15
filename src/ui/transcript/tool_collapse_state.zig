const std = @import("std");
const types = @import("../../core/shared/types.zig");

/// Three visually distinct collapse levels for Marionette-style hotkeys.
/// Ctrl+[ / Ctrl+] step between these; they must not collapse to a binary open/close.
pub const Level = enum {
    /// T0 umbrella only (`▶ Tool activity · N`).
    t0_only,
    /// T0 open + T1 group headers only (`▼` + `● N tool calls · …`).
    t1_headers,
    /// Individual tool rows (`├` / `└` status lines).
    t1_details,
};

/// Per-node expand/collapse for Marionette-style tiered transcript collapse.
/// Missing keys use defaults from `CollapseDefaults`.
pub const ToolCollapseTree = struct {
    turn_expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    group_expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    /// Sticky key for the live umbrella — set on first tool of a turn and
    /// reused by hotkeys + projection so mid-stream turn_id drift cannot
    /// leave force flags pointing at a different key than paint uses.
    preferred_turn_key: ?u64 = null,
    /// After stepping to `t1_headers`, unrecorded T1 nodes stay collapsed.
    t1_force_collapsed: bool = false,
    /// After stepping to `t1_details`, unrecorded T1 nodes stay expanded
    /// (overrides collapse_tool_calls defaults and t1_force_collapsed).
    t1_force_expanded: bool = false,
    /// When set, the next transcript paint must preserve the current
    /// viewport anchor instead of snapping to the composer/tail.
    preserve_viewport_on_next_paint: bool = false,

    pub fn deinit(self: *ToolCollapseTree, alloc: std.mem.Allocator) void {
        self.turn_expanded.deinit(alloc);
        self.group_expanded.deinit(alloc);
        self.* = .{};
    }

    pub fn setPreferredTurn(self: *ToolCollapseTree, turn_key: u64) void {
        self.preferred_turn_key = turn_key;
    }

    /// Stick the preferred turn on first tool of a live turn. Same key mid-stream
    /// is a no-op (avoids hotkey/projection drift). A different key means a new
    /// turn — advance preferred and clear prior force flags.
    pub fn ensurePreferredTurn(self: *ToolCollapseTree, turn_key: u64) void {
        if (self.preferred_turn_key == turn_key) return;
        self.preferred_turn_key = turn_key;
        self.t1_force_collapsed = false;
        self.t1_force_expanded = false;
    }

    pub fn turnIsExpanded(self: *const ToolCollapseTree, turn_key: u64, defaults: CollapseDefaults) bool {
        return self.turn_expanded.get(turn_key) orelse defaults.turn_expanded;
    }

    pub fn groupIsExpanded(self: *const ToolCollapseTree, group_key: u64, defaults: CollapseDefaults) bool {
        if (self.group_expanded.get(group_key)) |value| return value;
        if (self.t1_force_expanded) return true;
        if (self.t1_force_collapsed) return false;
        return defaults.group_expanded;
    }

    pub fn setTurnExpanded(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64, expanded: bool) !void {
        try self.turn_expanded.put(alloc, turn_key, expanded);
        self.preferred_turn_key = turn_key;
    }

    pub fn setGroupExpanded(self: *ToolCollapseTree, alloc: std.mem.Allocator, group_key: u64, expanded: bool) !void {
        try self.group_expanded.put(alloc, group_key, expanded);
    }

    pub fn levelForTurn(self: *const ToolCollapseTree, turn_key: u64, defaults: CollapseDefaults) Level {
        if (!self.turnIsExpanded(turn_key, defaults)) return .t0_only;
        if (self.t1_force_expanded) return .t1_details;
        if (self.t1_force_collapsed) return .t1_headers;
        // No force flag: derive from defaults (collapse_tool_calls → headers).
        if (defaults.group_expanded) return .t1_details;
        return .t1_headers;
    }

    fn applyLevel(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64, level: Level) !void {
        switch (level) {
            .t0_only => {
                try self.setTurnExpanded(alloc, turn_key, false);
                self.t1_force_collapsed = false;
                self.t1_force_expanded = false;
            },
            .t1_headers => {
                try self.setTurnExpanded(alloc, turn_key, true);
                self.t1_force_collapsed = true;
                self.t1_force_expanded = false;
                var it = self.group_expanded.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.* = false;
                }
            },
            .t1_details => {
                try self.setTurnExpanded(alloc, turn_key, true);
                self.t1_force_collapsed = false;
                self.t1_force_expanded = true;
                var it = self.group_expanded.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.* = true;
                }
            },
        }
    }

    /// Ctrl+] — step toward fuller detail.
    pub fn stepExpand(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64, defaults: CollapseDefaults) !void {
        const next: Level = switch (self.levelForTurn(turn_key, defaults)) {
            .t0_only => .t1_headers,
            .t1_headers => .t1_details,
            .t1_details => .t1_details,
        };
        try self.applyLevel(alloc, turn_key, next);
    }

    /// Ctrl+[ — step toward fuller collapse.
    pub fn stepCollapse(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64, defaults: CollapseDefaults) !void {
        const next: Level = switch (self.levelForTurn(turn_key, defaults)) {
            .t1_details => .t1_headers,
            .t1_headers => .t0_only,
            .t0_only => .t0_only,
        };
        try self.applyLevel(alloc, turn_key, next);
    }

    /// Ctrl+[ — collapse preferred turn to T0 umbrella only.
    pub fn collapseAllToT0(self: *ToolCollapseTree, alloc: std.mem.Allocator) !void {
        if (self.preferred_turn_key) |turn_key| {
            try self.applyLevel(alloc, turn_key, .t0_only);
            return;
        }
        var it = self.turn_expanded.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.* = false;
        }
        self.t1_force_collapsed = false;
        self.t1_force_expanded = false;
    }

    /// Ctrl+] — expand T0; keep T1 at headers only.
    pub fn expandT0KeepT1Collapsed(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64) !void {
        try self.applyLevel(alloc, turn_key, .t1_headers);
    }

    /// Expand T0 and all T1 groups to individual tool rows.
    pub fn expandT0AndT1Details(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64) !void {
        try self.applyLevel(alloc, turn_key, .t1_details);
    }

    pub fn toggleTurn(self: *ToolCollapseTree, alloc: std.mem.Allocator, turn_key: u64, defaults: CollapseDefaults) !void {
        const next = !self.turnIsExpanded(turn_key, defaults);
        try self.setTurnExpanded(alloc, turn_key, next);
        if (!next) {
            self.t1_force_collapsed = false;
            self.t1_force_expanded = false;
        }
    }

    pub fn markPreserveViewport(self: *ToolCollapseTree) void {
        self.preserve_viewport_on_next_paint = true;
    }

    pub fn takePreserveViewport(self: *ToolCollapseTree) bool {
        const value = self.preserve_viewport_on_next_paint;
        self.preserve_viewport_on_next_paint = false;
        return value;
    }

    /// After resume/history install, stick preferred to the newest tool turn so
    /// sticky/hotkey umbrella chrome is active immediately (tree is memory-only).
    pub fn reseedPreferredTurnFromToolDetails(self: *ToolCollapseTree, details: anytype) void {
        if (self.preferred_turn_key != null) return;
        if (newestTurnKeyFromToolDetails(details)) |key| {
            self.ensurePreferredTurn(key);
        }
    }
};

pub const CollapseDefaults = struct {
    turn_expanded: bool = true,
    group_expanded: bool = true,

    pub fn fromCollapseToolCalls(collapse_tool_calls: bool) CollapseDefaults {
        return .{
            .turn_expanded = true,
            .group_expanded = !collapse_tool_calls,
        };
    }
};

pub fn groupKeyForPresentation(group_id: types.ToolPresentationGroupId) u64 {
    return (@as(u64, @truncate(group_id.turn_id)) << 32) ^ group_id.anchor_step_id;
}

pub fn groupKeyForSequentialAnchor(entry_id: u32) u64 {
    return 0x8000_0000_0000_0000 | @as(u64, entry_id);
}

pub fn turnKeyFromLifecycle(turn_id: u64) u64 {
    return turn_id;
}

pub fn turnKeySynthetic(span_start_entry_id: u32) u64 {
    return 0xC000_0000_0000_0000 | @as(u64, span_start_entry_id);
}

/// Newest lifecycle/presentation turn key from loaded tool details (resume + hotkeys).
/// Walks in storage order so the last tool-bearing detail wins — same rule hotkeys use.
pub fn turnKeyFromToolDetail(detail: anytype) ?u64 {
    if (detail.lifecycle_id) |lifecycle| {
        return turnKeyFromLifecycle(lifecycle.turn_id);
    }
    if (detail.presentation_group_id) |group| {
        return turnKeyFromLifecycle(group.turn_id);
    }
    return null;
}

pub fn newestTurnKeyFromToolDetails(details: anytype) ?u64 {
    var newest: ?u64 = null;
    for (details) |detail| {
        if (turnKeyFromToolDetail(detail)) |key| newest = key;
    }
    return newest;
}


test "collapse defaults follow collapse_tool_calls" {
    const collapsed = CollapseDefaults.fromCollapseToolCalls(true);
    try std.testing.expect(collapsed.turn_expanded);
    try std.testing.expect(!collapsed.group_expanded);
    const expanded = CollapseDefaults.fromCollapseToolCalls(false);
    try std.testing.expect(expanded.group_expanded);
}

test "tree bracket ops" {
    const alloc = std.testing.allocator;
    var tree: ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    const defaults = CollapseDefaults.fromCollapseToolCalls(true);
    try tree.toggleTurn(alloc, 7, defaults);
    try std.testing.expect(!tree.turnIsExpanded(7, defaults));
    try tree.expandT0KeepT1Collapsed(alloc, 7);
    try std.testing.expect(tree.turnIsExpanded(7, defaults));
    try tree.setGroupExpanded(alloc, 99, true);
    try tree.expandT0KeepT1Collapsed(alloc, 7);
    try std.testing.expect(!tree.groupIsExpanded(99, defaults));
    try tree.collapseAllToT0(alloc);
    try std.testing.expect(!tree.turnIsExpanded(7, defaults));
}

test "stepExpand twice reaches t1_details with groups expanded" {
    const alloc = std.testing.allocator;
    var tree: ToolCollapseTree = .{};
    defer tree.deinit(alloc);
    const defaults = CollapseDefaults.fromCollapseToolCalls(true);
    try tree.applyLevel(alloc, 42, .t0_only);
    try std.testing.expectEqual(Level.t0_only, tree.levelForTurn(42, defaults));
    try tree.stepExpand(alloc, 42, defaults);
    try std.testing.expectEqual(Level.t1_headers, tree.levelForTurn(42, defaults));
    try std.testing.expect(!tree.groupIsExpanded(99, defaults));
    try tree.stepExpand(alloc, 42, defaults);
    try std.testing.expectEqual(Level.t1_details, tree.levelForTurn(42, defaults));
    try std.testing.expect(tree.groupIsExpanded(99, defaults));
    try tree.stepCollapse(alloc, 42, defaults);
    try std.testing.expectEqual(Level.t1_headers, tree.levelForTurn(42, defaults));
    try tree.stepCollapse(alloc, 42, defaults);
    try std.testing.expectEqual(Level.t0_only, tree.levelForTurn(42, defaults));
}

test "ensurePreferredTurn sticks mid-stream and advances on new turn" {
    var tree: ToolCollapseTree = .{};
    tree.ensurePreferredTurn(10);
    tree.ensurePreferredTurn(10);
    try std.testing.expectEqual(@as(?u64, 10), tree.preferred_turn_key);
    tree.t1_force_expanded = true;
    tree.ensurePreferredTurn(99);
    try std.testing.expectEqual(@as(?u64, 99), tree.preferred_turn_key);
    try std.testing.expect(!tree.t1_force_expanded);
}

test "newestTurnKeyFromToolDetails picks last lifecycle turn" {
    const Detail = struct {
        lifecycle_id: ?struct { turn_id: u64, call_id: []const u8 } = null,
        presentation_group_id: ?struct { turn_id: u64, anchor_step_id: u32 } = null,
    };
    const details = [_]Detail{
        .{ .lifecycle_id = .{ .turn_id = 3, .call_id = "a" } },
        .{ .presentation_group_id = .{ .turn_id = 9, .anchor_step_id = 1 } },
        .{ .lifecycle_id = .{ .turn_id = 7, .call_id = "b" } },
    };
    try std.testing.expectEqual(@as(?u64, 7), newestTurnKeyFromToolDetails(details[0..]));
    var tree: ToolCollapseTree = .{};
    tree.reseedPreferredTurnFromToolDetails(details[0..]);
    try std.testing.expectEqual(@as(?u64, 7), tree.preferred_turn_key);
    tree.reseedPreferredTurnFromToolDetails(details[0..]);
    try std.testing.expectEqual(@as(?u64, 7), tree.preferred_turn_key);
}

