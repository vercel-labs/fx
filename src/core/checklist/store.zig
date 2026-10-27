//! A session's checklist (D231). It lives in the session runtime beside
//! the kernel and the browser, so compaction, which rewrites only the
//! model's history, never touches it. Hosts save it with the session after
//! each turn they commit and load it back on resume.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const checklist = @import("checklist.zig");
const summary = @import("summary.zig");
const codec = @import("codec.zig");

const Allocator = std.mem.Allocator;
const List = checklist.List;

pub const Store = struct {
    /// Owns every list the store holds.
    gpa: Allocator = std.heap.c_allocator,
    mutex: std.Io.Mutex = .init,
    list: ?List = null,
    /// Counts changes; `saved` is the change the session last saved.
    revision: u64 = 0,
    saved: u64 = 0,

    pub fn deinit(self: *Store) void {
        if (self.list) |*list| list.deinit();
        self.list = null;
    }

    /// What one call did, for the model.
    pub const Outcome = struct {
        text: []u8,
        failed: bool,
        changed: bool,
    };

    /// Runs one call's arguments against the list. `arena` owns the text.
    pub fn run(self: *Store, arena: Allocator, args_json: []const u8) Allocator.Error!Outcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var empty: List = .init(self.gpa);
        defer empty.deinit();
        const current: *const List = if (self.list) |*list| list else &empty;
        const request = switch (try checklist.parseRequest(arena, args_json, current.taskCount() > 0)) {
            .request => |value| value,
            .invalid => |reason| return .{ .text = try arena.print("{s}\n{s}", .{ reason, summary.view_hint }), .failed = true, .changed = false },
        };
        var applied = try checklist.apply(self.gpa, current, request);
        var kept = false;
        defer if (!kept) applied.deinit();
        const text = try summary.resultText(arena, current, &applied.list, request, applied.errors);
        if (applied.failed()) return .{ .text = text, .failed = true, .changed = false };
        const changed = !current.eql(&applied.list);
        if (changed) {
            if (self.list) |*old| old.deinit();
            self.list = applied.list;
            kept = true;
            self.revision += 1;
        }
        return .{ .text = text, .failed = false, .changed = changed };
    }

    /// A copy of the list, or null when it holds no tasks. Caller owns it.
    pub fn snapshot(self: *Store, gpa: Allocator) Allocator.Error!?List {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const list = if (self.list) |*value| value else return null;
        if (list.taskCount() == 0) return null;
        return try list.clone(gpa);
    }

    pub const Changed = struct { list: ?List, revision: u64 };

    /// A copy of the list when it changed after `revision`, with the
    /// revision it reflects, for the live panel (D252); null when it did
    /// not change. The copy is null when the list holds no tasks. Caller
    /// owns it.
    pub fn snapshotSince(self: *Store, gpa: Allocator, revision: u64) Allocator.Error!?Changed {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.revision == revision) return null;
        const copy: ?List = if (self.list) |*value| (if (value.taskCount() > 0) try value.clone(gpa) else null) else null;
        return .{ .list = copy, .revision = self.revision };
    }

    /// Replaces the list with a saved one, or clears it for null. A saved
    /// list that does not read is dropped with the reason returned.
    pub fn restore(self: *Store, json: ?[]const u8) error{ OutOfMemory, InvalidChecklist }!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.list) |*old| old.deinit();
        self.list = null;
        self.revision += 1;
        self.saved = self.revision;
        const raw = json orelse return;
        self.list = try codec.decode(self.gpa, raw);
    }

    pub fn clear(self: *Store) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.list) |*old| old.deinit();
        self.list = null;
        self.revision += 1;
    }

    /// The list's JSON when it changed since the last save, with the
    /// change it records; pass that to `markSaved` once it is written.
    pub const Pending = struct { json: []u8, revision: u64 };

    pub fn pendingSave(self: *Store, alloc: Allocator) Allocator.Error!?Pending {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.revision == self.saved) return null;
        var empty: List = .init(alloc);
        defer empty.deinit();
        const list: *const List = if (self.list) |*value| value else &empty;
        return .{ .json = try codec.encode(alloc, list), .revision = self.revision };
    }

    pub fn markSaved(self: *Store, revision: u64) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (revision > self.saved) self.saved = revision;
    }
};

test "a store applies calls, keeps failures out, and saves only changes" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: Store = .{ .gpa = testing.allocator };
    defer store.deinit();

    const made = try store.run(a, "{\"op\":\"init\",\"items\":[\"one\",\"two\"]}");
    try testing.expect(made.changed and !made.failed);
    const missing = try store.run(a, "{\"op\":\"done\",\"task\":\"three\"}");
    try testing.expect(missing.failed and !missing.changed);
    const viewed = try store.run(a, "{\"op\":\"view\"}");
    try testing.expect(!viewed.changed);

    const pending = (try store.pendingSave(testing.allocator)).?;
    defer testing.allocator.free(pending.json);
    store.markSaved(pending.revision);
    try testing.expectEqual(@as(?Store.Pending, null), try store.pendingSave(testing.allocator));

    _ = try store.run(a, "{\"op\":\"done\",\"task\":\"one\"}");
    var resumed: Store = .{ .gpa = testing.allocator };
    defer resumed.deinit();
    const later = (try store.pendingSave(testing.allocator)).?;
    defer testing.allocator.free(later.json);
    try resumed.restore(later.json);
    var copy = (try resumed.snapshot(testing.allocator)).?;
    defer copy.deinit();
    try testing.expectEqual(checklist.Status.completed, copy.phases.items[0].tasks.items[0].status);
    try testing.expectEqual(checklist.Status.in_progress, copy.phases.items[0].tasks.items[1].status);
    try testing.expectEqual(@as(?Store.Pending, null), try resumed.pendingSave(testing.allocator));
}
