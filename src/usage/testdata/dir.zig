//! A read-only directory over the embedded fixtures (`fixtures.zig`),
//! with the parts of `std.Io.Dir` the fixture tests use, so they read
//! embedded bytes instead of the working directory. Tests only.

const std = @import("std");
const fixtures = @import("fixtures.zig");

pub const Error = error{ FileNotFound, NameTooLong, StreamTooLong, OutOfMemory };

pub const Entry = struct {
    /// Borrowed from the manifest; valid for the whole test run.
    name: []const u8,
    kind: std.Io.File.Kind,
};

pub const Dir = struct {
    prefix_buffer: [256]u8 = undefined,
    prefix_len: usize = 0,

    /// A top-level fixture directory, such as "compat".
    pub fn open(path: []const u8) Error!Dir {
        return (Dir{}).openDir(undefined, path, .{});
    }

    fn prefix(dir: *const Dir) []const u8 {
        return dir.prefix_buffer[0..dir.prefix_len];
    }

    pub fn openDir(dir: Dir, _: std.Io, path: []const u8, _: std.Io.Dir.OpenOptions) Error!Dir {
        var sub: Dir = .{};
        const joined = std.fmt.bufPrint(&sub.prefix_buffer, "{s}{s}/", .{ dir.prefix(), path }) catch return error.NameTooLong;
        sub.prefix_len = joined.len;
        for (fixtures.files) |file| {
            if (std.mem.startsWith(u8, file.path, joined)) return sub;
        }
        return error.FileNotFound;
    }

    pub fn close(_: *Dir, _: std.Io) void {}

    /// The embedded bytes at `path` under this directory.
    pub fn bytes(dir: *const Dir, path: []const u8) Error![]const u8 {
        var buffer: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buffer, "{s}{s}", .{ dir.prefix(), path }) catch return error.NameTooLong;
        for (fixtures.files) |file| {
            if (std.mem.eql(u8, file.path, full)) return file.bytes;
        }
        return error.FileNotFound;
    }

    pub fn readFileAlloc(dir: Dir, _: std.Io, path: []const u8, gpa: std.mem.Allocator, limit: std.Io.Limit) Error![]u8 {
        const found = try dir.bytes(path);
        if (found.len > limit.toInt().?) return error.StreamTooLong;
        return gpa.dupe(u8, found);
    }

    pub fn iterate(dir: Dir) Iterator {
        return .{ .dir = dir };
    }
};

/// Direct children in path order, each directory once.
pub const Iterator = struct {
    dir: Dir,
    index: usize = 0,
    last_directory: []const u8 = "",

    pub fn next(it: *Iterator, _: std.Io) Error!?Entry {
        const prefix = it.dir.prefix();
        while (it.index < fixtures.files.len) {
            const path = fixtures.files[it.index].path;
            it.index += 1;
            if (!std.mem.startsWith(u8, path, prefix)) continue;
            const rest = path[prefix.len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const name = rest[0..slash];
                if (std.mem.eql(u8, name, it.last_directory)) continue;
                it.last_directory = name;
                return .{ .name = name, .kind = .directory };
            }
            return .{ .name = rest, .kind = .file };
        }
        return null;
    }
};

test "the embedded tree lists, opens, and reads like a directory" {
    var compat = try Dir.open("compat");
    defer compat.close(std.testing.io);
    var saw_cases = false;
    var saw_readme = false;
    var it = compat.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "cases")) saw_cases = entry.kind == .directory;
        if (std.mem.eql(u8, entry.name, "README.md")) saw_readme = entry.kind == .file;
    }
    try std.testing.expect(saw_cases and saw_readme);
    const cases = try compat.openDir(std.testing.io, "cases", .{});
    const corpus = try cases.readFileAlloc(std.testing.io, "record.jsonl", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(corpus);
    try std.testing.expect(corpus.len > 0);
    try std.testing.expectError(error.FileNotFound, compat.openDir(std.testing.io, "missing", .{}));
    try std.testing.expectError(error.FileNotFound, compat.bytes("missing.json"));
}
