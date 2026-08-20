const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const OperationKind = enum {
    write,
    edit,
    delete,
    rename,
};

pub const FileOperation = struct {
    kind: OperationKind,
    path: []u8,
    previous_content: ?[]u8,
    new_path: ?[]u8 = null,
    timestamp_ms: i64,
    /// Set when the file's state before the mutation could not be read. Such an
    /// operation is still recorded, so undo consumes it and says so, rather than
    /// silently undoing an older operation the user did not ask about.
    preimage_unavailable: bool = false,
};

pub const UndoResult = union(enum) {
    restored: []const u8,
    deleted: []const u8,
    /// The operation was consumed but could not be reversed, either because its
    /// preimage was never captured or because restoring it failed. Undo must not
    /// guess, and must not report this as a restore.
    unavailable: []const u8,
    empty,
};

/// The state of a file before a mutation. `absent` means the file was proven not to
/// exist, which is the only case that licenses undo to delete it again; `unavailable`
/// means the state could not be read (too large, permissions, IO error) and nothing
/// about the file may be assumed.
pub const CaptureResult = union(enum) {
    captured: []u8,
    absent,
    unavailable,
};

pub const ChangeTracker = struct {
    stack: std.ArrayList(FileOperation) = .empty,

    const max_stack_size: usize = 100;

    pub fn deinit(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.deinit(alloc);
    }

    pub fn clear(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.clearRetainingCapacity();
    }

    pub fn pushOperation(self: *ChangeTracker, alloc: Allocator, op: FileOperation) !void {
        if (self.stack.items.len >= max_stack_size) {
            freeOperation(alloc, self.stack.items[0]);
            _ = self.stack.orderedRemove(0);
        }
        try self.stack.append(alloc, op);
    }

    pub fn undoLast(self: *ChangeTracker, alloc: Allocator) UndoResult {
        if (self.stack.items.len == 0) return .empty;

        const op = self.stack.pop().?;
        defer if (op.new_path) |new_path| alloc.free(new_path);

        if (op.preimage_unavailable) {
            if (op.previous_content) |content| alloc.free(content);
            return .{ .unavailable = op.path };
        }

        switch (op.kind) {
            .delete => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch {
                        alloc.free(op.path);
                        return .empty;
                    };
                    return .{ .restored = op.path };
                }
                alloc.free(op.path);
                return .empty;
            },
            .rename => {
                if (op.new_path) |new_path| {
                    std.Io.Dir.renameAbsolute(new_path, op.path, io_mod.getIo()) catch {
                        if (op.previous_content) |content| alloc.free(content);
                        alloc.free(op.path);
                        return .empty;
                    };
                    // previous_content holds the overwritten destination preimage.
                    if (op.previous_content) |content| {
                        defer alloc.free(content);
                        restoreContent(alloc, new_path, content) catch {
                            // The rename back succeeded but the file it displaced could
                            // not be put back. Undo the rename too, so the tree is left
                            // as it was rather than half reversed under a success report.
                            std.Io.Dir.renameAbsolute(op.path, new_path, io_mod.getIo()) catch {
                                return .{ .unavailable = op.path };
                            };
                            alloc.free(op.path);
                            return .empty;
                        };
                    }
                    return .{ .restored = op.path };
                }
                if (op.previous_content) |content| alloc.free(content);
                return .{ .restored = op.path };
            },
            .write, .edit => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch {
                        alloc.free(op.path);
                        return .empty;
                    };
                    return .{ .restored = op.path };
                }

                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), op.path) catch {};
                return .{ .deleted = op.path };
            },
        }
    }

    pub fn captureFileState(alloc: Allocator, absolute_path: []const u8) CaptureResult {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{}) catch |err| {
            return if (err == error.FileNotFound) .absent else .unavailable;
        };
        defer file.close(io_mod.getIo());
        const content = io_mod.readFileToEnd(alloc, &file, 10 * 1024 * 1024) catch return .unavailable;
        return .{ .captured = content };
    }

    /// Restores `content` at `absolute_path` without destroying what is already there
    /// until the replacement is durable. A failed restore leaves the current file
    /// untouched and is reported to the caller rather than swallowed.
    ///
    /// Two properties of the old truncate-in-place restore are kept deliberately.
    /// Symlinks are resolved first, so undoing an edit to a linked file rewrites the
    /// file the link points at instead of replacing the link with a regular file. And
    /// a directory that denies writes still permits an in-place restore, because
    /// rewriting an existing file never needed permission on its parent; that path
    /// cannot be atomic, so it is taken only when the atomic one is refused.
    fn restoreContent(alloc: Allocator, absolute_path: []const u8, content: []const u8) !void {
        const resolved = io_mod.realpathAlloc(alloc, absolute_path) catch null;
        defer if (resolved) |path| alloc.free(path);
        const target = resolved orelse absolute_path;

        io_mod.writeFileAtomic(alloc, target, content) catch |err| switch (err) {
            error.AccessDenied, error.ReadOnlyFileSystem => try restoreInPlace(target, content),
            else => return err,
        };
    }

    /// Rewrites `content` over an existing file without unlinking it. The file is
    /// truncated to the restored length only after every byte is written, so a failed
    /// write cannot shorten it and is still reported.
    fn restoreInPlace(absolute_path: []const u8, content: []const u8) !void {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), absolute_path, .{ .truncate = false });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
        try file.setLength(io_mod.getIo(), content.len);
        try file.sync(io_mod.getIo());
    }

    fn freeOperation(alloc: Allocator, op: FileOperation) void {
        alloc.free(op.path);
        if (op.previous_content) |content| alloc.free(content);
        if (op.new_path) |new_path| alloc.free(new_path);
    }
};

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, "");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn expectMissing(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
        file.close(io_mod.getIo());
        return error.FileStillExists;
    } else |_| {}
}

test "undoLast returns empty on an initially empty stack" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "clear releases operations and leaves the tracker empty" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, "/workspace/a.txt"),
        .previous_content = try alloc.dupe(u8, "before"),
        .new_path = try alloc.dupe(u8, "/workspace/b.txt"),
        .timestamp_ms = 1,
    });

    tracker.clear(alloc);

    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, "/workspace/reused.txt"),
        .previous_content = null,
        .timestamp_ms = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqualStrings("/workspace/reused.txt", tracker.stack.items[0].path);
}

test "pushOperation evicts the oldest operation with stable ordering" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    for (0..ChangeTracker.max_stack_size + 1) |i| {
        try tracker.pushOperation(alloc, .{
            .kind = .write,
            .path = try std.fmt.allocPrint(alloc, "/tracked/file-{d}", .{i}),
            .previous_content = null,
            .timestamp_ms = @intCast(i),
        });
    }

    try std.testing.expectEqual(ChangeTracker.max_stack_size, tracker.stack.items.len);
    try std.testing.expectEqualStrings("/tracked/file-1", tracker.stack.items[0].path);
    try std.testing.expectEqualStrings("/tracked/file-100", tracker.stack.items[tracker.stack.items.len - 1].path);
}

test "undoLast restores previous content for write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "modified");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "original"),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("original", content);
}

test "undoLast deletes new write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "new content");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast reports deleted for a new write when the file is already absent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "already-absent.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast restores deleted files when previous content exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "deleted.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .delete,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "restored"),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("restored", content);
}

test "undoLast returns empty for deleted files without previous content" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .delete,
        .path = try alloc.dupe(u8, "/workspace/deleted.txt"),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "undoLast renames new_path back to path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "old.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(new_path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), new_path) catch {};

    try writeAbsolute(new_path, "moved");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = null,
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(old_path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const content = try readAbsolute(alloc, old_path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("moved", content);
    try expectMissing(new_path);
}

test "undoLast restores destination preimage after overwrite rename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "source.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "dest.txt");
    defer alloc.free(new_path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), old_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), new_path) catch {};

    // After overwrite rename, only dest exists with the source bytes.
    try writeAbsolute(new_path, "source-bytes");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = try alloc.dupe(u8, "dest-preimage"),
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(old_path, restored_path);
        },
        else => return error.ExpectedRestore,
    }

    const source = try readAbsolute(alloc, old_path);
    defer alloc.free(source);
    try std.testing.expectEqualStrings("source-bytes", source);
    const dest = try readAbsolute(alloc, new_path);
    defer alloc.free(dest);
    try std.testing.expectEqualStrings("dest-preimage", dest);
}

test "undoLast consumes rename operations when renaming back fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "old-missing.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new-missing.txt");
    defer alloc.free(new_path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .previous_content = try alloc.dupe(u8, "unused"),
        .new_path = try alloc.dupe(u8, new_path),
        .timestamp_ms = 1,
    });

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "undoLast returns restored for rename operations without new_path" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, "/workspace/original.txt"),
        .previous_content = try alloc.dupe(u8, "previous"),
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings("/workspace/original.txt", restored_path);
        },
        else => return error.ExpectedRestore,
    }
}

test "undoLast pops before filesystem restore failures and does not create parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "missing-parent/file.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "content"),
        .timestamp_ms = 1,
    });

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try expectMissing(path);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "captureFileState captures existing files and returns null for missing files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "capture.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "snapshot");

    const captured = switch (ChangeTracker.captureFileState(alloc, path)) {
        .captured => |content| content,
        else => return error.ExpectedCapture,
    };
    defer alloc.free(captured);
    try std.testing.expectEqualStrings("snapshot", captured);

    const missing_path = try tmpPath(alloc, tmp.dir, "missing.txt");
    defer alloc.free(missing_path);
    try std.testing.expect(ChangeTracker.captureFileState(alloc, missing_path) == .absent);
}

test "captureFileState reports unavailable for files at the size limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "limit.bin");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.setLength(io_mod.getIo(), 10 * 1024 * 1024);

    try std.testing.expect(ChangeTracker.captureFileState(alloc, path) == .unavailable);
}

test "captureFileState reports unavailable for files over the size limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "over-limit.bin");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.setLength(io_mod.getIo(), 10 * 1024 * 1024 + 1);

    try std.testing.expect(ChangeTracker.captureFileState(alloc, path) == .unavailable);
}

test "undoLast leaves the original file intact when the restore write fails" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore-target.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    const current = "bytes the user still has on disk";
    try writeAbsolute(path, current);

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'R');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    // Fail every write past 4 KiB, without the file-size signal killing the test process.
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    const saved_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = 4096, .max = saved_limit.max });
    defer std.posix.setrlimit(.FSIZE, saved_limit) catch {};

    try std.testing.expect(tracker.undoLast(alloc) == .empty);

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings(current, survived);
}

test "captureFileState separates absent from unavailable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_path = try tmpPath(alloc, tmp.dir, "missing.txt");
    defer alloc.free(missing_path);
    try std.testing.expect(ChangeTracker.captureFileState(alloc, missing_path) == .absent);

    const oversized_path = try tmpPath(alloc, tmp.dir, "oversized.bin");
    defer alloc.free(oversized_path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), oversized_path) catch {};
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), oversized_path, .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), 10 * 1024 * 1024 + 1);
    }
    try std.testing.expect(ChangeTracker.captureFileState(alloc, oversized_path) == .unavailable);
}

test "undoLast refuses an operation whose preimage was never captured" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "uncaptured.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "content the tool did not create");

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
        .preimage_unavailable = true,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("content the tool did not create", survived);
}

test "undo restores a file whose directory denies writes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/file.txt");
    defer alloc.free(path);
    try writeAbsolute(path, "current bytes");

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeZ(u8, dir_path);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .restored => |restored| alloc.free(restored),
        else => return error.ExpectedRestore,
    }
    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("preimage bytes", survived);
}

test "undo rewrites the file a symlink points at rather than replacing the link" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real_path = try tmpPath(alloc, tmp.dir, "real.txt");
    defer alloc.free(real_path);
    const link_path = try tmpPath(alloc, tmp.dir, "link.txt");
    defer alloc.free(link_path);
    try writeAbsolute(real_path, "current bytes");
    tmp.dir.symLink(std.testing.io, real_path, "link.txt", .{ .is_directory = false }) catch return error.SkipZigTest;

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, link_path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .restored => |restored| alloc.free(restored),
        else => return error.ExpectedRestore,
    }

    const link_stat = try tmp.dir.statFile(io_mod.getIo(), "link.txt", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    const through_link = try readAbsolute(alloc, real_path);
    defer alloc.free(through_link);
    try std.testing.expectEqualStrings("preimage bytes", through_link);
}

test "undo rolls back a rename when the displaced file cannot be restored" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try tmpPath(alloc, tmp.dir, "old.txt");
    defer alloc.free(old_path);
    const new_path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(new_path);
    try writeAbsolute(new_path, "renamed content");

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'D');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .rename,
        .path = try alloc.dupe(u8, old_path),
        .new_path = try alloc.dupe(u8, new_path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    const saved_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = 4096, .max = saved_limit.max });
    defer std.posix.setrlimit(.FSIZE, saved_limit) catch {};

    try std.testing.expect(tracker.undoLast(alloc) == .empty);

    // The tree is left exactly as it was before the undo attempt.
    const displaced = try readAbsolute(alloc, new_path);
    defer alloc.free(displaced);
    try std.testing.expectEqualStrings("renamed content", displaced);
    try expectMissing(old_path);
}
