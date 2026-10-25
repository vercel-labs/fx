//! Inline navigation state. The supervisor owns execution and session lifetimes.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
pub const Scope = enum { sessions, subagents };
pub const Row = struct {
    id: []const u8,
    parent_id: []const u8 = "",
    title: []const u8,
    status: []const u8 = "",
    detail: []const u8 = "",
    /// Right-aligned compact metadata: an age for saved sessions, a state for
    /// running children. Kept separate from `detail`, which stays next to the
    /// title.
    meta: []const u8 = "",
    depth: usize = 0,
    current: bool = false,
};
pub const State = struct {
    active: bool = false,
    scope: Scope = .sessions,
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},
    selected: usize = 0,
    window_start: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    error_buf: [160]u8 = undefined,
    error_len: usize = 0,
    loading: bool = false,
    /// The selected session awaiting delete confirmation. It is copied so a
    /// live list update cannot move the action to another row. A valid id is
    /// at most 255 bytes (`session_layout.validateSessionId`).
    pending_delete_buf: [256]u8 = undefined,
    pending_delete_len: usize = 0,

    pub fn close(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn open(self: *State, scope: Scope) void {
        self.close();
        self.active = true;
        self.scope = scope;
        self.loading = true;
    }
    /// Copies compact summaries; the snapshot belongs to this state.
    pub fn replaceRows(self: *State, alloc: std.mem.Allocator, rows: []const Row) !void {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.alloc(Row, rows.len);
        for (rows, owned) |row, *out| {
            out.* = row;
            out.id = try a.dupe(u8, row.id);
            out.parent_id = try a.dupe(u8, row.parent_id);
            out.title = (try text_utils.encodeTerminalSafeInline(a, row.title, 512)).bytes;
            out.status = (try text_utils.encodeTerminalSafeInline(a, row.status, 128)).bytes;
            out.detail = (try text_utils.encodeTerminalSafeInline(a, row.detail, 1024)).bytes;
            out.meta = (try text_utils.encodeTerminalSafeInline(a, row.meta, 128)).bytes;
        }
        const selected_id = if (self.selectedRow()) |row| row.id else "";
        var selected: ?usize = null;
        var filtered: usize = 0;
        for (owned) |row| {
            if (!self.matches(row)) continue;
            if (std.mem.eql(u8, row.id, selected_id)) selected = filtered;
            filtered += 1;
        }
        if (self.arena) |*previous| previous.deinit();
        self.arena = arena;
        self.rows = owned;
        self.selected = selected orelse @min(self.selected, filtered -| 1);
        self.window_start = @min(self.window_start, self.selected);
        self.loading = false;
        self.error_len = 0;
    }
    pub fn fail(self: *State, message: []const u8) void {
        self.error_len = @min(message.len, self.error_buf.len);
        @memcpy(self.error_buf[0..self.error_len], message[0..self.error_len]);
        self.loading = false;
    }
    pub fn query(self: *const State) []const u8 {
        return self.query_buf[0..self.query_len];
    }
    pub fn setQuery(self: *State, value: []const u8) void {
        self.query_len = @min(value.len, self.query_buf.len);
        @memmove(self.query_buf[0..self.query_len], value[0..self.query_len]);
        self.selected = 0;
        self.window_start = 0;
    }
    fn matches(self: *const State, row: Row) bool {
        const needle = self.query();
        return needle.len == 0 or containsIgnoreCase(row.title, needle) or containsIgnoreCase(row.id, needle) or containsIgnoreCase(row.detail, needle) or containsIgnoreCase(row.meta, needle);
    }
    pub fn itemAt(self: *const State, index: usize) ?*const Row {
        var matched: usize = 0;
        for (self.rows) |*row| {
            if (!self.matches(row.*)) continue;
            if (matched == index) return row;
            matched += 1;
        }
        return null;
    }
    pub fn count(self: *const State) usize {
        var n: usize = 0;
        for (self.rows) |row| {
            if (self.matches(row)) n += 1;
        }
        return n;
    }
    pub fn selectedRow(self: *const State) ?*const Row {
        return self.itemAt(self.selected);
    }
    /// Starts delete confirmation for the selected session. False for no
    /// selection or the session in view, which cannot delete itself.
    pub fn beginDelete(self: *State) bool {
        const row = self.selectedRow() orelse return false;
        if (row.current) return false;
        self.pending_delete_len = @min(row.id.len, self.pending_delete_buf.len);
        @memmove(self.pending_delete_buf[0..self.pending_delete_len], row.id[0..self.pending_delete_len]);
        return true;
    }
    pub fn pendingDeleteId(self: *const State) ?[]const u8 {
        return if (self.pending_delete_len == 0) null else self.pending_delete_buf[0..self.pending_delete_len];
    }
    pub fn cancelDelete(self: *State) void {
        self.pending_delete_len = 0;
    }
    pub fn move(self: *State, delta: i32, visible: usize) void {
        self.selected = if (delta < 0) self.selected -| @as(usize, @intCast(-delta)) else @min(self.selected +| @as(usize, @intCast(delta)), self.count() -| 1);
        if (self.selected < self.window_start) self.window_start = self.selected;
        if (self.selected >= self.window_start + @max(visible, 1)) self.window_start = self.selected + 1 - @max(visible, 1);
    }
};
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
test "browser selection follows identity across live changes" {
    var state: State = .{};
    defer state.close();
    state.open(.subagents);
    try state.replaceRows(std.testing.allocator, &.{ .{ .id = "one", .title = "First" }, .{ .id = "two", .title = "Second" } });
    state.move(1, 10);
    try state.replaceRows(std.testing.allocator, &.{ .{ .id = "two", .title = "Second", .status = "finished" }, .{ .id = "one", .title = "First" } });
    try std.testing.expectEqualStrings("two", state.selectedRow().?.id);
    state.setQuery("first");
    try std.testing.expectEqualStrings("one", state.selectedRow().?.id);
}

test "delete confirmation keeps the chosen session across list updates" {
    var state: State = .{};
    defer state.close();
    state.open(.sessions);
    try state.replaceRows(std.testing.allocator, &.{
        .{ .id = "current", .title = "Current", .current = true },
        .{ .id = "other", .title = "Other" },
    });
    state.selected = 0;
    try std.testing.expect(!state.beginDelete());
    state.selected = 1;
    try std.testing.expect(state.beginDelete());
    try std.testing.expectEqualStrings("other", state.pendingDeleteId().?);
    try state.replaceRows(std.testing.allocator, &.{
        .{ .id = "current", .title = "Current", .current = true },
        .{ .id = "newer", .title = "Newer" },
        .{ .id = "other", .title = "Other" },
    });
    try std.testing.expectEqualStrings("other", state.pendingDeleteId().?);
    state.cancelDelete();
    try std.testing.expect(state.pendingDeleteId() == null);
}

test "browser metadata is copied and searchable" {
    var state: State = .{};
    defer state.close();
    state.open(.sessions);
    try state.replaceRows(std.testing.allocator, &.{
        .{ .id = "one", .title = "First", .meta = "12m" },
        .{ .id = "two", .title = "Second", .meta = "running" },
    });
    try std.testing.expectEqualStrings("12m", state.itemAt(0).?.meta);
    state.setQuery("running");
    try std.testing.expectEqual(@as(usize, 1), state.count());
    try std.testing.expectEqualStrings("two", state.itemAt(0).?.id);
}
