//! Bounded reads of untrusted metadata files. Only existing regular files are
//! read: a final symlink is not followed, FIFOs and devices are refused
//! without blocking, and content larger than the cap is refused rather than
//! truncated, so a caller never acts on a partial file.

const std = @import("std");
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
    var file = io_mod.openExistingReadOnlyRegularFile(dir, sub_path, .no_follow) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .{ .unavailable = @errorName(err) },
    };
    defer file.close(io_mod.getIo());
    // The reader reports a stream that fills its limit as too long, so allow
    // one extra byte to accept a file of exactly `max_bytes`.
    const data = io_mod.readFileToEnd(alloc, &file, max_bytes +| 1) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => .{ .unavailable = "too_large" },
        else => .{ .unavailable = @errorName(err) },
    };
    return .{ .content = data };
}

/// Reads an absolute `path`.
pub fn readAbsolute(alloc: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!Outcome {
    if (!std.fs.path.isAbsolute(path)) return .{ .unavailable = "relative_path" };
    return readAt(alloc, std.Io.Dir.cwd(), path, max_bytes);
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
