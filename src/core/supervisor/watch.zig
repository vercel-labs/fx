//! The connections watching one session, and what each was last sent.
//!
//! A watcher sees the session's events and record from the snapshot that
//! started its watch (`Session.pushUpdates`), and, when it asked, one node's
//! children list and one node's transcript, at any depth of the session's
//! tree (`Session.pushViews`). A node no one watches costs no reads or
//! pushes. Each watcher holds a reference on its connection.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const protocol = @import("protocol.zig");
const Conn = @import("server.zig").Conn;
const Allocator = std.mem.Allocator;

pub fn digest(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Where a watched child transcript stands: the cursor the viewer would
/// send in its next `history` request.
const ChildCursor = struct {
    child_id: []u8,
    parent_id: []u8,
    work_id: []u8,
    live_sequence: u64,
    live_active: bool,
    status: u64,

    fn init(alloc: Allocator, view: anytype) !ChildCursor {
        const child_id = try alloc.dupe(u8, view.child_id);
        errdefer alloc.free(child_id);
        const parent_id = try alloc.dupe(u8, view.parent_id);
        errdefer alloc.free(parent_id);
        return .{
            .child_id = child_id,
            .parent_id = parent_id,
            .work_id = try alloc.dupe(u8, view.work_id),
            .live_sequence = view.live_sequence,
            .live_active = view.live_active,
            .status = digest(view.status),
        };
    }

    fn deinit(self: *ChildCursor, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.parent_id);
        alloc.free(self.work_id);
        self.* = undefined;
    }

    pub fn request(self: *const ChildCursor, session_id: []const u8) protocol.History {
        return .{
            .session_id = session_id,
            .child_id = self.child_id,
            .parent_id = if (self.parent_id.len > 0) self.parent_id else null,
            .work_id = self.work_id,
            .after_live_sequence = self.live_sequence,
            .live_active = self.live_active,
            .include_history = false,
        };
    }

    /// Whether `view`, read with this cursor, shows the viewer anything new.
    pub fn changedBy(self: *const ChildCursor, view: anytype) bool {
        return view.live_reset or view.live_sequence != self.live_sequence or digest(view.status) != self.status;
    }

    pub fn advance(self: *ChildCursor, alloc: Allocator, view: anytype) !void {
        if (!std.mem.eql(u8, self.work_id, view.work_id)) {
            const work_id = try alloc.dupe(u8, view.work_id);
            alloc.free(self.work_id);
            self.work_id = work_id;
        }
        self.live_sequence = view.live_sequence;
        self.live_active = view.live_active;
        self.status = digest(view.status);
    }
};

pub const ChildrenWatch = struct {
    node_id: []u8,
    /// The digest of the list last sent.
    digest: u64,
};

const Watcher = struct {
    conn: *Conn,
    /// The last event sequence and session version this watcher was sent.
    sequence: u64,
    version: u64,
    /// The node whose children list is watched, and what was last sent.
    children: ?ChildrenWatch = null,
    child: ?ChildCursor = null,

    fn deinit(self: *Watcher, alloc: Allocator) void {
        if (self.children) |list| alloc.free(list.node_id);
        if (self.child) |*cursor| cursor.deinit(alloc);
        self.conn.release();
        self.* = undefined;
    }
};

pub const Watchers = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Watcher) = .empty,

    pub fn deinit(self: *Watchers, alloc: Allocator) void {
        for (self.items.items) |*watcher| watcher.deinit(alloc);
        self.items.deinit(alloc);
        self.* = undefined;
    }

    /// Holds `mutex`.
    fn find(self: *Watchers, conn: *Conn) ?*Watcher {
        for (self.items.items) |*watcher| if (watcher.conn == conn) return watcher;
        return null;
    }

    /// Starts `conn` watching from the snapshot that covered `sequence` and
    /// `version`, replacing any watch it had here.
    pub fn watch(self: *Watchers, alloc: Allocator, conn: *Conn, sequence: u64, version: u64) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.find(conn)) |watcher| {
            if (watcher.children) |list| alloc.free(list.node_id);
            if (watcher.child) |*cursor| cursor.deinit(alloc);
            watcher.* = .{ .conn = conn, .sequence = sequence, .version = version };
            return;
        }
        try self.items.append(alloc, .{ .conn = conn.retain(), .sequence = sequence, .version = version });
    }

    pub fn forget(self: *Watchers, alloc: Allocator, conn: *Conn) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.items.items, 0..) |*watcher, index| if (watcher.conn == conn) {
            watcher.deinit(alloc);
            _ = self.items.swapRemove(index);
            return;
        };
    }

    pub fn unwatch(self: *Watchers, alloc: Allocator, conn: *Conn, topic: protocol.Topic) void {
        if (topic == .session) return self.forget(alloc, conn);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const watcher = self.find(conn) orelse return;
        switch (topic) {
            .session, .list, .stopped => {},
            .children => if (watcher.children) |list| {
                alloc.free(list.node_id);
                watcher.children = null;
            },
            .child => if (watcher.child) |*cursor| {
                cursor.deinit(alloc);
                watcher.child = null;
            },
        }
    }

    /// Watches node `node_id`'s children list, which `conn` was just sent,
    /// if it watches this session. It replaces any list watched before.
    pub fn watchChildren(self: *Watchers, alloc: Allocator, conn: *Conn, node_id: []const u8, bytes: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const watcher = self.find(conn) orelse return;
        const owned = try alloc.dupe(u8, node_id);
        if (watcher.children) |list| alloc.free(list.node_id);
        watcher.children = .{ .node_id = owned, .digest = digest(bytes) };
    }

    /// Watches the child transcript `conn` was just sent, from where `view`
    /// leaves it, if it watches this session.
    pub fn watchChild(self: *Watchers, alloc: Allocator, conn: *Conn, view: anytype) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const watcher = self.find(conn) orelse return;
        const cursor = try ChildCursor.init(alloc, view);
        if (watcher.child) |*old| old.deinit(alloc);
        watcher.child = cursor;
    }

    /// Pushes each watched children list and node transcript that changed.
    /// `views` reads them: `children(arena, node_id)` and
    /// `childView(arena, request)`, the bodies their requests return.
    pub fn pushViews(self: *Watchers, alloc: Allocator, views: anytype) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.items.items) |*watcher| {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            if (watcher.children) |*list| if (views.children(arena, list.node_id)) |bytes| {
                const value = digest(bytes);
                if (value != list.digest) {
                    watcher.conn.push(arena, .children, bytes) catch {};
                    list.digest = value;
                }
            } else |_| {};
            if (watcher.child) |*cursor| {
                const view = views.childView(arena, cursor.request(views.id)) catch continue;
                if (!cursor.changedBy(view)) continue;
                const bytes = protocol.encode(arena, view) catch continue;
                watcher.conn.push(arena, .child, bytes) catch {};
                cursor.advance(alloc, view) catch {};
            }
        }
    }

    /// Drops watchers whose connection ended. Holds `mutex`.
    pub fn pruneLocked(self: *Watchers, alloc: Allocator) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            const watcher = &self.items.items[index];
            if (watcher.conn.isOpen()) {
                index += 1;
                continue;
            }
            watcher.deinit(alloc);
            _ = self.items.swapRemove(index);
        }
    }
};

test "a child cursor reports only new output or a changed status" {
    const alloc = std.testing.allocator;
    const View = struct { child_id: []const u8, parent_id: []const u8 = "mid", work_id: []const u8, live_sequence: u64, live_active: bool, live_reset: bool = false, status: []const u8 };
    var cursor = try ChildCursor.init(alloc, View{ .child_id = "c", .work_id = "w1", .live_sequence = 3, .live_active = true, .status = "running" });
    defer cursor.deinit(alloc);
    try std.testing.expect(!cursor.changedBy(View{ .child_id = "c", .work_id = "w1", .live_sequence = 3, .live_active = true, .status = "running" }));
    try std.testing.expect(cursor.changedBy(View{ .child_id = "c", .work_id = "w1", .live_sequence = 4, .live_active = true, .status = "running" }));
    try std.testing.expect(cursor.changedBy(View{ .child_id = "c", .work_id = "w1", .live_sequence = 3, .live_active = false, .status = "finished" }));
    try cursor.advance(alloc, View{ .child_id = "c", .work_id = "w2", .live_sequence = 0, .live_active = false, .live_reset = true, .status = "finished" });
    const next = cursor.request("s");
    try std.testing.expectEqualStrings("w2", next.work_id.?);
    try std.testing.expect(!next.include_history and !next.live_active);
    // A node below a child is read under its real parent.
    try std.testing.expectEqualStrings("mid", next.parent_id.?);
}
