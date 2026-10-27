//! Folds of a node's Python state lines (D99), computed on demand from the
//! log rather than kept in `State`, so snapshots stay small however many
//! values or kernel snapshots a session keeps.
//!
//! Every `store_set`, `store_del` and `kernel_snapshot` line names the turn
//! it was written in, and turn numbers never repeat, so a line belongs to a
//! turn a rewind dropped exactly when its turn is in `State.dropped`. Both
//! folds skip those lines; nothing else is needed for a rewind. A rewind to
//! a checkpoint (D120) drops no whole turn, so it keeps the Python state as
//! it is. A fork copies
//! the lines through its point with its source's rewinds, so the same folds
//! over the fork's own log give the state at the fork point
//! (`tests/tla/session_manager/PythonState.tla` `RestoreExact`).
const std = @import("std");
const schema = @import("schema.zig");
const fold = @import("fold.zig");
const session_mod = @import("session.zig");

const Page = session_mod.Page;
const From = session_mod.From;
const Direction = session_mod.Direction;

const page_lines = 256;

/// A kernel's globals as one `kernel_snapshot` line names them. Owns its
/// slices through `arena`.
pub const Kernel = struct {
    arena: std.heap.ArenaAllocator,
    turn: u64,
    seq: u64,
    names: []const []const u8,
    blobs: []const []const u8,
    /// fx's raw JSON list of the globals the snapshot could not hold.
    failed: []const u8,

    pub fn deinit(self: *Kernel) void {
        self.arena.deinit();
    }
};

/// The newest `kernel_snapshot` of kernel `name` in a kept turn, or null.
/// Read backward from the end: a `rewound` line comes after every line it
/// drops, and `dropped` holds them all anyway. `reader` has
/// `read(gpa, from, direction, limit) !Page`.
pub fn latestKernel(gpa: std.mem.Allocator, reader: anytype, dropped: []const fold.Dropped, name: []const u8) !?Kernel {
    var from: From = .end;
    while (true) {
        var page = try reader.read(gpa, from, .backward, page_lines);
        defer page.deinit();
        for (page.entries) |entry| {
            const body = entry.body orelse continue;
            if (body != .kernel_snapshot) continue;
            const line = body.kernel_snapshot;
            if (!std.mem.eql(u8, line.kernel, name) or fold.isDropped(dropped, line.turn)) continue;
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const a = arena.allocator();
            return .{
                .turn = line.turn,
                .seq = entry.seq,
                .names = try dupeAll(a, line.names),
                .blobs = try dupeAll(a, line.blobs),
                .failed = try a.dupe(u8, line.failed),
                .arena = arena,
            };
        }
        from = .{ .at = page.next orelse return null };
    }
}

/// A node's store: each kept key and the blob of its value, in the order
/// keys were first set. Owns its slices through `arena`.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    values: std.array_hash_map.String([]const u8) = .empty,

    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

/// Applies every store line of a kept turn in log order.
pub fn store(gpa: std.mem.Allocator, reader: anytype, dropped: []const fold.Dropped) !Store {
    var result: Store = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    var from: From = .start;
    while (true) {
        var page = try reader.read(gpa, from, .forward, page_lines);
        defer page.deinit();
        for (page.entries) |entry| try applyStore(&result, dropped, entry.body orelse continue);
        from = .{ .at = page.next orelse break };
    }
    return result;
}

/// One line of `store`'s fold; any other kind is ignored.
pub fn applyStore(result: *Store, dropped: []const fold.Dropped, body: schema.Body) !void {
    const a = result.arena.allocator();
    switch (body) {
        .store_set => |v| {
            if (fold.isDropped(dropped, v.turn)) return;
            const slot = try result.values.getOrPut(a, v.key);
            if (!slot.found_existing) slot.key_ptr.* = try a.dupe(u8, v.key);
            slot.value_ptr.* = try a.dupe(u8, v.blob[0]);
        },
        .store_del => |v| {
            if (fold.isDropped(dropped, v.turn)) return;
            _ = result.values.orderedRemove(v.key);
        },
        else => {},
    }
}

fn dupeAll(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try a.dupe(u8, item);
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A log held in memory for the folds: entries in order, read in pages.
const MemoryLog = struct {
    bodies: []const schema.Body,

    pub fn read(self: MemoryLog, gpa: std.mem.Allocator, from: From, direction: Direction, limit: usize) !Page {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const n = self.bodies.len;
        var entries: std.ArrayList(session_mod.Entry) = .empty;
        var next: ?session_mod.Cursor = null;
        switch (direction) {
            .forward => {
                var i: usize = switch (from) {
                    .start => 0,
                    .end => n,
                    .at => |c| @intCast(c.offset),
                };
                while (i < n and entries.items.len < limit) : (i += 1) try entries.append(arena.allocator(), entry(self.bodies[i], i));
                if (i < n) next = .{ .offset = i, .seq = i + 1 };
            },
            .backward => {
                var i: usize = switch (from) {
                    .start => 0,
                    .end => n,
                    .at => |c| @intCast(c.offset),
                };
                while (i > 0 and entries.items.len < limit) : (i -= 1) try entries.append(arena.allocator(), entry(self.bodies[i - 1], i - 1));
                if (i > 0) next = .{ .offset = i, .seq = i };
            },
        }
        return .{ .arena = arena, .entries = entries.items, .next = next, .damaged = false };
    }

    fn entry(body: schema.Body, i: usize) session_mod.Entry {
        return .{ .seq = i + 1, .offset = i, .ts_ms = 0, .kind = std.meta.activeTag(body), .kind_name = @tagName(std.meta.activeTag(body)), .body = body };
    }
};

const hash_a_bytes: [64]u8 = @splat('a');
const hash_b_bytes: [64]u8 = @splat('b');
const hash_c_bytes: [64]u8 = @splat('c');
const hash_a: []const u8 = &hash_a_bytes;
const hash_b: []const u8 = &hash_b_bytes;
const hash_c: []const u8 = &hash_c_bytes;

fn snap(turn: u64, kernel: []const u8, blob: *const [1][]const u8) schema.Body {
    return .{ .kernel_snapshot = .{ .turn = turn, .kernel = kernel, .names = &.{"x"}, .blobs = blob } };
}

test "the kernel fold takes the newest snapshot of a kept turn" {
    const a: [1][]const u8 = .{hash_a};
    const b: [1][]const u8 = .{hash_b};
    const c: [1][]const u8 = .{hash_c};
    const bodies = [_]schema.Body{
        snap(1, "default", &a),
        snap(2, "default", &b),
        snap(2, "other", &c),
        .{ .rewound = .{ .turn = 2, .through = 2 } },
        snap(3, "other", &a),
    };
    const log: MemoryLog = .{ .bodies = &bodies };
    // Turn 2 was dropped, so the default kernel goes back to turn 1.
    var found = (try latestKernel(testing.allocator, log, &.{.{ .turn = 2, .through = 2 }}, "default")).?;
    defer found.deinit();
    try testing.expectEqual(@as(u64, 1), found.turn);
    try testing.expectEqualStrings(hash_a, found.blobs[0]);
    // Without the rewind the newest wins, and kernels are kept apart.
    var newest = (try latestKernel(testing.allocator, log, &.{}, "default")).?;
    defer newest.deinit();
    try testing.expectEqualStrings(hash_b, newest.blobs[0]);
    var other = (try latestKernel(testing.allocator, log, &.{.{ .turn = 2, .through = 2 }}, "other")).?;
    defer other.deinit();
    try testing.expectEqual(@as(u64, 3), other.turn);
    try testing.expect((try latestKernel(testing.allocator, log, &.{}, "none")) == null);
}

test "the store fold applies sets and deletes of kept turns only" {
    const a: [1][]const u8 = .{hash_a};
    const b: [1][]const u8 = .{hash_b};
    const bodies = [_]schema.Body{
        .{ .store_set = .{ .turn = 1, .key = "k", .blob = &a } },
        .{ .store_set = .{ .turn = 1, .key = "gone", .blob = &a } },
        .{ .store_del = .{ .turn = 2, .key = "gone" } },
        .{ .store_set = .{ .turn = 3, .key = "k", .blob = &b } },
        .{ .store_set = .{ .turn = 3, .key = "late", .blob = &b } },
        .{ .rewound = .{ .turn = 3, .through = 3 } },
    };
    const log: MemoryLog = .{ .bodies = &bodies };
    var kept = try store(testing.allocator, log, &.{.{ .turn = 3, .through = 3 }});
    defer kept.deinit();
    try testing.expectEqualStrings(hash_a, kept.get("k").?);
    try testing.expect(kept.get("gone") == null);
    try testing.expect(kept.get("late") == null);
    try testing.expectEqual(@as(usize, 1), kept.values.count());
    var all = try store(testing.allocator, log, &.{});
    defer all.deinit();
    try testing.expectEqualStrings(hash_b, all.get("k").?);
    try testing.expectEqual(@as(usize, 2), all.values.count());
}
