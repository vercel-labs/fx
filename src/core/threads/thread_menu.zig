//! State of the `/thread` menu: a scrollable list of the current session's
//! threads, with `main` first, that Enter switches to.
//!
//! The rows are a snapshot the app builds from the thread registry and the
//! subagent host. The menu owns their text, so a frame can borrow it while the
//! UI thread is the only writer.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Row = struct {
    /// The name Enter switches to. `main` is the session the threads stem from.
    label: []u8,
    /// State and what the thread was asked, for the dim column.
    info: []u8,
    /// Where the user is now.
    current: bool,

    fn deinit(self: Row, alloc: Allocator) void {
        alloc.free(self.label);
        alloc.free(self.info);
    }
};

pub const State = struct {
    active: bool = false,
    selected_index: usize = 0,
    rows: []Row = &.{},
    /// When the rows were last rebuilt, so a menu left open stays current.
    refreshed_ms: i64 = 0,

    /// Takes ownership of `rows`. The selection starts on the current row.
    pub fn open(self: *State, alloc: Allocator, rows: []Row, now_ms: i64) void {
        self.release(alloc);
        self.* = .{ .active = true, .rows = rows, .refreshed_ms = now_ms };
        for (rows, 0..) |row, index| {
            if (row.current) self.selected_index = index;
        }
    }

    /// Swaps in fresh rows and keeps the selection on the same name.
    pub fn refresh(self: *State, alloc: Allocator, rows: []Row, now_ms: i64) void {
        if (!self.active) {
            for (rows) |row| row.deinit(alloc);
            alloc.free(rows);
            return;
        }
        var keep: ?usize = null;
        if (self.selected()) |row| {
            for (rows, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate.label, row.label)) keep = index;
            }
        }
        const next_index = keep orelse @min(self.selected_index, rows.len -| 1);
        self.release(alloc);
        self.rows = rows;
        self.selected_index = next_index;
        self.active = true;
        self.refreshed_ms = now_ms;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        self.release(alloc);
        self.* = .{};
    }

    fn release(self: *State, alloc: Allocator) void {
        for (self.rows) |row| row.deinit(alloc);
        if (self.rows.len > 0) alloc.free(self.rows);
        self.rows = &.{};
    }

    pub fn move(self: *State, delta: i32) bool {
        const count = self.rows.len;
        if (!self.active or delta == 0 or count == 0) return false;
        const count_signed: i32 = @intCast(count);
        var next: i32 = @intCast(self.selected_index % count);
        next += delta;
        while (next < 0) next += count_signed;
        while (next >= count_signed) next -= count_signed;
        self.selected_index = @intCast(next);
        return true;
    }

    pub fn selected(self: *const State) ?*const Row {
        if (!self.active or self.rows.len == 0) return null;
        return &self.rows[self.selected_index % self.rows.len];
    }
};

pub const RowSpec = struct { label: []const u8, info: []const u8, current: bool };

/// Builds a row set from borrowed text. Caller passes the result to `open` or
/// `refresh`.
pub fn makeRows(alloc: Allocator, specs: []const RowSpec) Allocator.Error![]Row {
    const rows = try alloc.alloc(Row, specs.len);
    var made: usize = 0;
    errdefer {
        for (rows[0..made]) |row| row.deinit(alloc);
        alloc.free(rows);
    }
    for (specs, rows) |spec, *row| {
        const label = try alloc.dupe(u8, spec.label);
        errdefer alloc.free(label);
        row.* = .{ .label = label, .info = try alloc.dupe(u8, spec.info), .current = spec.current };
        made += 1;
    }
    return rows;
}

test "the menu opens on the current row, wraps, and keeps its selection across refreshes" {
    const alloc = std.testing.allocator;
    var state = State{};
    defer state.close(alloc);
    state.open(alloc, try makeRows(alloc, &.{
        .{ .label = "main", .info = "current session", .current = false },
        .{ .label = "alpha", .info = "running", .current = true },
        .{ .label = "beta", .info = "idle", .current = false },
    }), 10);
    try std.testing.expectEqualStrings("alpha", state.selected().?.label);

    try std.testing.expect(state.move(1));
    try std.testing.expectEqualStrings("beta", state.selected().?.label);
    try std.testing.expect(state.move(1));
    try std.testing.expectEqualStrings("main", state.selected().?.label);
    try std.testing.expect(state.move(-1));
    try std.testing.expectEqualStrings("beta", state.selected().?.label);

    // A thread appearing above keeps the selection on beta, not on its old index.
    state.refresh(alloc, try makeRows(alloc, &.{
        .{ .label = "main", .info = "current session", .current = false },
        .{ .label = "aaa", .info = "idle", .current = false },
        .{ .label = "alpha", .info = "idle", .current = true },
        .{ .label = "beta", .info = "idle", .current = false },
    }), 20);
    try std.testing.expectEqualStrings("beta", state.selected().?.label);
    try std.testing.expectEqual(@as(i64, 20), state.refreshed_ms);

    // A thread that was deleted leaves the selection on a row that exists.
    state.refresh(alloc, try makeRows(alloc, &.{
        .{ .label = "main", .info = "current session", .current = true },
    }), 30);
    try std.testing.expectEqualStrings("main", state.selected().?.label);
}

test "a closed menu ignores moves and refreshes and frees what it was given" {
    const alloc = std.testing.allocator;
    var state = State{};
    try std.testing.expect(!state.move(1));
    try std.testing.expect(state.selected() == null);
    state.refresh(alloc, try makeRows(alloc, &.{.{ .label = "main", .info = "", .current = true }}), 1);
    try std.testing.expect(!state.active);
    state.close(alloc);
}
