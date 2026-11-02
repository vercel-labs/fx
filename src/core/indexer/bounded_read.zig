//! Bounded reads of untrusted metadata files. Only existing regular files are
//! read: a final symlink is not followed, FIFOs and devices are refused
//! without blocking, and content larger than the cap is refused rather than
//! truncated, so a caller never acts on a partial file.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = union(enum) {
    /// Content owned by the allocator passed to the read.
    content: []u8,
    missing,
    /// Present but unsafe, unreadable, or over the cap. Static string.
    unavailable: []const u8,
};

/// Reads `sub_path` relative to `dir`, accepting at most `max_bytes`.
pub fn readAt(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    return readWith(alloc, dir, sub_path, max_bytes, .no_follow);
}

/// Reads an absolute `path`.
pub fn readAbsolute(alloc: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    if (!std.Io.Dir.path.isAbsolute(path)) return .{ .unavailable = "relative_path" };
    return readAt(alloc, std.Io.Dir.cwd(), path, max_bytes);
}

/// Reads an absolute `path` that the user's own git config or environment
/// names, following a final symlink as git does, since dotfile managers often
/// link these files. The target must still be a regular file within the cap.
/// Paths a repository names use `readAbsolute`.
pub fn readUserAbsolute(alloc: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    if (!std.Io.Dir.path.isAbsolute(path)) return .{ .unavailable = "relative_path" };
    return readWith(alloc, std.Io.Dir.cwd(), path, max_bytes, .follow);
}

fn readWith(
    alloc: Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    max_bytes: usize,
    final_symlink: io_mod.FinalSymlinkPolicy,
) Allocator.Error!Outcome {
    const file = io_mod.openExistingReadOnlyRegularFile(dir, sub_path, final_symlink) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .{ .unavailable = @errorName(err) },
    };
    defer file.close(io_mod.getIo());
    if (try readSized(alloc, file, max_bytes)) |outcome| return outcome;
    // The file holds more than its stat said: it grew, or its file system
    // reports no size, as Linux does for /proc. A positional reader would stop
    // at the stat size, so read it as a stream, which never trusts one.
    var read_buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &read_buffer);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    // A stream that fills its limit reads as too long, so allow one extra byte
    // to accept a file of exactly `max_bytes`.
    reader.interface.appendRemaining(alloc, &content, .limited(max_bytes +| 1)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => .{ .unavailable = "too_large" },
        error.ReadFailed => .{ .unavailable = if (reader.err) |read_err| @errorName(read_err) else @errorName(err) },
    };
    return .{ .content = try content.toOwnedSlice(alloc) };
}

/// Reads the whole file into a buffer sized from its stat, so a small file
/// does not claim a stream reader's growth buffer. Returns null when the file
/// holds more than its stat said, which the caller reads as a stream.
fn readSized(alloc: Allocator, file: std.Io.File, max_bytes: usize) Allocator.Error!?Outcome {
    const io = io_mod.getIo();
    const stat = file.stat(io) catch |err| return .{ .unavailable = @errorName(err) };
    if (stat.size > max_bytes) return .{ .unavailable = "too_large" };
    // `stat.size <= max_bytes`, so it fits in a usize.
    const size: usize = @intCast(stat.size);
    // One byte past the size shows whether the file grew since the stat.
    const buffer = try alloc.alloc(u8, size + 1);
    const read = file.readPositionalAll(io, buffer, 0) catch |err| {
        alloc.free(buffer);
        return .{ .unavailable = @errorName(err) };
    };
    if (read > size) {
        alloc.free(buffer);
        return null;
    }
    return .{ .content = try alloc.realloc(buffer, read) };
}

test "bounded reads return content, missing, oversize and non-regular outcomes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small", .data = "abc" });
    try tmp.dir.createDirPath(std.testing.io, "dir");

    const small = try readAt(alloc, tmp.dir, "small", 3);
    defer alloc.free(small.content);
    try std.testing.expectEqualStrings("abc", small.content);
    try std.testing.expect(try readAt(alloc, tmp.dir, "absent", 16) == .missing);
    try std.testing.expectEqualStrings("too_large", (try readAt(alloc, tmp.dir, "small", 2)).unavailable);
    try std.testing.expect(try readAt(alloc, tmp.dir, "dir", 16) == .unavailable);

    tmp.dir.symLink(std.testing.io, "small", "link", .{}) catch return error.SkipZigTest;
    try std.testing.expect(try readAt(alloc, tmp.dir, "link", 16) == .unavailable);
    try std.testing.expect(try readAbsolute(alloc, "relative", 16) == .unavailable);
}

test "bounded reads allocate the file's size, not a stream buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small", .data = "0123456789" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = counting.allocator();

    const small = try readAt(alloc, tmp.dir, "small", 1024 * 1024);
    defer alloc.free(small.content);
    try std.testing.expectEqualStrings("0123456789", small.content);
    try std.testing.expect(counting.allocated_bytes <= 64);

    const empty = try readAt(alloc, tmp.dir, "empty", 1024 * 1024);
    defer alloc.free(empty.content);
    try std.testing.expectEqual(@as(usize, 0), empty.content.len);
}

test "bounded reads stream a regular file whose stat reports no size" {
    // Linux reports 0 bytes for the regular files under /proc.
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const status = try readUserAbsolute(alloc, "/proc/self/status", 1024 * 1024);
    defer alloc.free(status.content);
    try std.testing.expect(std.mem.startsWith(u8, status.content, "Name:"));
}

test "user reads follow a final symlink to a regular file and still refuse the rest" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gitconfig", .data = "[core]\n" });
    try tmp.dir.createDirPath(std.testing.io, "dir");
    tmp.dir.symLink(std.testing.io, "gitconfig", "linked", .{}) catch return error.SkipZigTest;
    try tmp.dir.symLink(std.testing.io, "dir", "linked-dir", .{});
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const linked = try std.Io.Dir.path.join(alloc, &.{ root, "linked" });
    defer alloc.free(linked);
    const followed = try readUserAbsolute(alloc, linked, 16);
    defer alloc.free(followed.content);
    try std.testing.expectEqualStrings("[core]\n", followed.content);
    // A repository-named path still refuses the same link.
    try std.testing.expect(try readAbsolute(alloc, linked, 16) == .unavailable);

    const linked_dir = try std.Io.Dir.path.join(alloc, &.{ root, "linked-dir" });
    defer alloc.free(linked_dir);
    try std.testing.expect(try readUserAbsolute(alloc, linked_dir, 16) == .unavailable);
    try std.testing.expectEqualStrings("too_large", (try readUserAbsolute(alloc, linked, 2)).unavailable);
    try std.testing.expect(try readUserAbsolute(alloc, "relative", 16) == .unavailable);

    // A link to a FIFO is refused without waiting for a writer.
    const fifo = try std.Io.Dir.path.joinZ(alloc, &.{ root, "fifo" });
    defer alloc.free(fifo);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try tmp.dir.symLink(std.testing.io, "fifo", "linked-fifo", .{});
    const linked_fifo = try std.Io.Dir.path.join(alloc, &.{ root, "linked-fifo" });
    defer alloc.free(linked_fifo);
    try std.testing.expect(try readUserAbsolute(alloc, linked_fifo, 16) == .unavailable);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
