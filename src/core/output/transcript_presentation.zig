const std = @import("std");

pub const Event = enum {
    toggle,
    left,
    right,
};

pub const Depth = enum {
    inline_mode,
    full,

    pub fn transition(self: Depth, event: Event) Depth {
        return switch (event) {
            .toggle => if (self == .inline_mode) .full else .inline_mode,
            .left, .right => if (self.active()) .full else .inline_mode,
        };
    }

    pub fn active(self: Depth) bool {
        return self != .inline_mode;
    }
};

pub const ScrollDirection = enum {
    up,
    down,
};

pub const ItemRow = struct {
    entry_id: u32,
    row: u32,
};

pub const Snapshot = struct {
    depth: Depth,
    scroll_rows: u32,
    follow_tail: bool,
    anchor_entry_id: ?u32,
    anchor_pending: bool,
    bookmark_entry_id: ?u32,
    bookmark_intra_row: u32,
    bookmark_pending: bool,
    projection_cols: ?u16,
};

pub const OffsetSelection = struct {
    state: State,
    offset: u32,
};

pub const State = struct {
    depth: Depth = .inline_mode,
    scroll_rows: u32 = 0,
    follow_tail: bool = true,
    anchor_entry_id: ?u32 = null,
    anchor_pending: bool = false,
    bookmark_entry_id: ?u32 = null,
    bookmark_intra_row: u32 = 0,
    bookmark_pending: bool = false,
    projection_cols: ?u16 = null,

    pub fn with_depth(self: State, requested: Depth) State {
        if (self.depth == requested) return self;

        var next = self;
        next = switch (requested) {
            .inline_mode => next.closed(),
            .full => next.open_full(),
        };
        return next;
    }

    pub fn closed(self: State) State {
        var next = self.reset_viewport().clear_anchor();
        next.depth = .inline_mode;
        return next;
    }

    pub fn clear_anchor(self: State) State {
        var next = self;
        next.anchor_entry_id = null;
        next.anchor_pending = false;
        next.bookmark_entry_id = null;
        next.bookmark_intra_row = 0;
        next.bookmark_pending = false;
        next.projection_cols = null;
        return next;
    }

    pub fn capture_anchor(self: State, entry_id: ?u32) State {
        var next = self;
        next.anchor_entry_id = entry_id;
        next.anchor_pending = entry_id != null;
        return next;
    }

    pub fn retarget_anchor(self: State, entry_id: u32) State {
        var next = self;
        next.anchor_entry_id = entry_id;
        return next;
    }

    pub fn select_page_boundary(self: State, entry_id: u32) State {
        var next = self;
        next.scroll_rows = 0;
        next.follow_tail = false;
        next.anchor_pending = false;
        next.bookmark_entry_id = entry_id;
        next.bookmark_intra_row = 0;
        next.bookmark_pending = true;
        return next;
    }

    pub fn prepare_projection(self: State, cols: u16) State {
        var next = self;
        if (next.projection_cols) |previous_cols| {
            if (previous_cols != cols) next = next.queue_bookmark();
        }
        next.projection_cols = cols;
        return next;
    }

    pub fn scroll(self: State, direction: ScrollDirection, rows: u32) State {
        var next = self;
        next.follow_tail = false;
        next.bookmark_pending = false;
        switch (direction) {
            .up => next.scroll_rows -|= rows,
            .down => next.scroll_rows +|= rows,
        }
        return next;
    }

    pub fn select_visual_offset(
        self: State,
        total_rows: u32,
        visible_rows: u16,
        item_rows: []const ItemRow,
    ) OffsetSelection {
        var next = self;
        const max_offset = total_rows -| visible_rows;
        const anchor_rows = resolve_bookmark_row(item_rows, next.anchor_entry_id);
        const offset = if (next.bookmark_pending) blk: {
            next.bookmark_pending = false;
            next.follow_tail = false;
            const item_row = resolve_bookmark_row(
                item_rows,
                next.bookmark_entry_id,
            ) orelse break :blk @min(next.scroll_rows, max_offset);
            const item_end = next_bookmark_item_row(item_rows, item_row) orelse
                total_rows;
            const max_intra_row = item_end -| item_row -| 1;
            break :blk @min(
                item_row +| @min(next.bookmark_intra_row, max_intra_row),
                max_offset,
            );
        } else if (next.anchor_pending and anchor_rows != null) blk: {
            next.anchor_pending = false;
            next.follow_tail = false;
            break :blk @min(anchor_rows.?, max_offset);
        } else if (next.follow_tail)
            max_offset
        else
            @min(next.scroll_rows, max_offset);

        next.scroll_rows = offset;
        next.follow_tail = offset == max_offset;
        next = next.refresh_bookmark(item_rows, offset);
        return .{ .state = next, .offset = offset };
    }

    pub fn snapshot(self: State) Snapshot {
        return .{
            .depth = self.depth,
            .scroll_rows = self.scroll_rows,
            .follow_tail = self.follow_tail,
            .anchor_entry_id = self.anchor_entry_id,
            .anchor_pending = self.anchor_pending,
            .bookmark_entry_id = self.bookmark_entry_id,
            .bookmark_intra_row = self.bookmark_intra_row,
            .bookmark_pending = self.bookmark_pending,
            .projection_cols = self.projection_cols,
        };
    }

    pub fn from_snapshot(saved: Snapshot) State {
        return .{
            .depth = saved.depth,
            .scroll_rows = saved.scroll_rows,
            .follow_tail = saved.follow_tail,
            .anchor_entry_id = saved.anchor_entry_id,
            .anchor_pending = saved.anchor_pending,
            .bookmark_entry_id = saved.bookmark_entry_id,
            .bookmark_intra_row = saved.bookmark_intra_row,
            .bookmark_pending = saved.bookmark_pending,
            .projection_cols = saved.projection_cols,
        };
    }

    fn open_full(self: State) State {
        var next = self.reset_viewport();
        next.depth = .full;
        // The identity remains available for retention retargeting, but a
        // normal open starts at the tail instead of consuming the old anchor.
        next.anchor_pending = false;
        return next;
    }

    fn reset_viewport(self: State) State {
        var next = self;
        next.scroll_rows = 0;
        next.follow_tail = true;
        return next;
    }

    fn queue_bookmark(self: State) State {
        var next = self;
        next.bookmark_pending = !next.follow_tail and next.bookmark_entry_id != null;
        return next;
    }

    fn refresh_bookmark(
        self: State,
        item_rows: []const ItemRow,
        offset: u32,
    ) State {
        var selected: ?ItemRow = null;
        for (item_rows) |item| {
            if (item.row > offset) break;
            selected = item;
        }
        const item = selected orelse if (item_rows.len > 0)
            item_rows[0]
        else
            return self;
        var next = self;
        next.bookmark_entry_id = item.entry_id;
        next.bookmark_intra_row = offset -| item.row;
        return next;
    }
};

fn resolve_bookmark_row(item_rows: []const ItemRow, entry_id: ?u32) ?u32 {
    const target = entry_id orelse return null;
    var preceding: ?ItemRow = null;
    var following: ?ItemRow = null;
    for (item_rows) |item| {
        if (item.entry_id == target) return item.row;
        if (item.entry_id < target) {
            if (preceding == null or item.entry_id > preceding.?.entry_id) {
                preceding = item;
            }
        } else if (following == null or item.entry_id < following.?.entry_id) {
            following = item;
        }
    }
    return if (preceding) |item|
        item.row
    else if (following) |item|
        item.row
    else
        null;
}

fn next_bookmark_item_row(item_rows: []const ItemRow, current_row: u32) ?u32 {
    for (item_rows) |item| {
        if (item.row > current_row) return item.row;
    }
    return null;
}

test "transcript presentation depth preserves viewer transitions" {
    try std.testing.expect(std.meta.stringToEnum(Depth, "review") == null);
    const Case = struct {
        from: Depth,
        input: Event,
        expected: Depth,
    };
    const cases = [_]Case{
        .{ .from = .inline_mode, .input = .toggle, .expected = .full },
        .{ .from = .full, .input = .toggle, .expected = .inline_mode },
        .{ .from = .inline_mode, .input = .left, .expected = .inline_mode },
        .{ .from = .full, .input = .left, .expected = .full },
        .{ .from = .inline_mode, .input = .right, .expected = .inline_mode },
        .{ .from = .full, .input = .right, .expected = .full },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            case.from.transition(case.input),
        );
    }
}

test "transcript presentation scroll saturates and leaves follow tail" {
    const initial = State{ .scroll_rows = 1 };
    const at_start = initial.scroll(.up, 3);
    try std.testing.expectEqual(@as(u32, 0), at_start.scroll_rows);
    try std.testing.expect(!at_start.follow_tail);

    const near_end = State{ .scroll_rows = std.math.maxInt(u32) - 1 };
    const at_end = near_end.scroll(.down, 3);
    try std.testing.expectEqual(std.math.maxInt(u32), at_end.scroll_rows);
}

test "transcript presentation clamps bookmarks and selects retained neighbor" {
    const item_rows = [_]ItemRow{
        .{ .entry_id = 10, .row = 1 },
        .{ .entry_id = 30, .row = 8 },
    };
    const clamped = (State{
        .scroll_rows = 4,
        .follow_tail = false,
        .bookmark_entry_id = 10,
        .bookmark_intra_row = 99,
        .bookmark_pending = true,
    }).select_visual_offset(14, 4, &item_rows);
    try std.testing.expectEqual(@as(u32, 7), clamped.offset);

    const neighbor = (State{
        .scroll_rows = 4,
        .follow_tail = false,
        .bookmark_entry_id = 20,
        .bookmark_pending = true,
    }).select_visual_offset(14, 4, &item_rows);
    try std.testing.expectEqual(@as(u32, 1), neighbor.offset);
    try std.testing.expectEqual(@as(?u32, 10), neighbor.state.bookmark_entry_id);

    const following = (State{
        .scroll_rows = 4,
        .follow_tail = false,
        .bookmark_entry_id = 5,
        .bookmark_intra_row = 1,
        .bookmark_pending = true,
    }).select_visual_offset(14, 4, &item_rows);
    try std.testing.expectEqual(@as(u32, 2), following.offset);
    try std.testing.expectEqual(@as(?u32, 10), following.state.bookmark_entry_id);
}

test "transcript presentation snapshot round trips all state" {
    const state = State{
        .depth = .full,
        .scroll_rows = 7,
        .follow_tail = false,
        .anchor_entry_id = 11,
        .anchor_pending = true,
        .bookmark_entry_id = 12,
        .bookmark_intra_row = 2,
        .bookmark_pending = true,
        .projection_cols = 40,
    };
    try std.testing.expectEqualDeep(state, State.from_snapshot(state.snapshot()));
}
