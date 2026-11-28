//! Everything a monitor prints, kept in a file the agent can read with
//! `read_file`, whatever the events showed. A session's files live in
//! `~/.fx/monitors/<session-id>/`, one `<monitor-id>.log` for each monitor. A
//! file that reaches `max_file_bytes` becomes `<monitor-id>.log.1`, replacing
//! the one before it, so a monitor keeps its newest output in at most twice
//! that size. A normal quit, a new conversation, and the restart note remove
//! the session's folder.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

const folder_name = "monitors";

/// The size at which a monitor's file rolls over to `.log.1`.
pub const max_file_bytes: u64 = 4 * 1024 * 1024;

/// Whether `name` is a plain session or monitor id, so it can never name
/// another folder.
fn plainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

/// A session's folder. Caller owns the result.
fn folderPath(alloc: Allocator, home: []const u8, session_id: []const u8) ![]u8 {
    if (!plainName(session_id)) return error.InvalidName;
    return profile_paths.rootPath(alloc, home, &.{ folder_name, session_id });
}

/// The file a monitor's output goes to. Caller owns the result.
pub fn filePath(alloc: Allocator, home: []const u8, session_id: []const u8, monitor_id: []const u8) ![]u8 {
    if (!plainName(session_id) or !plainName(monitor_id)) return error.InvalidName;
    const name = try alloc.print("{s}.log", .{monitor_id});
    defer alloc.free(name);
    return profile_paths.rootPath(alloc, home, &.{ folder_name, session_id, name });
}

/// Adds `bytes` to the monitor's file, which only its owner can read.
pub fn append(alloc: Allocator, home: []const u8, session_id: []const u8, monitor_id: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const folder = try folderPath(alloc, home, session_id);
    defer alloc.free(folder);
    try io_mod.makeDirRecursive(folder);
    const path = try filePath(alloc, home, session_id, monitor_id);
    defer alloc.free(path);
    const io = io_mod.getIo();
    var file = try openForAppend(path);
    var size = (try file.stat(io)).size;
    if (size >= max_file_bytes) {
        file.close(io);
        const older = try alloc.print("{s}.1", .{path});
        defer alloc.free(older);
        try std.Io.Dir.renameAbsolute(path, older, io);
        file = try openForAppend(path);
        size = 0;
    }
    defer file.close(io);
    try file.writePositionalAll(io, bytes, size);
}

fn openForAppend(path: []const u8) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = false,
        .permissions = .fromMode(0o600),
    });
}

/// Removes a session's folder and every file in it. Nothing to remove is fine.
pub fn removeSession(alloc: Allocator, home: []const u8, session_id: []const u8) void {
    const folder = folderPath(alloc, home, session_id) catch return;
    defer alloc.free(folder);
    // A folder that is gone, or that cannot be removed, leaves only output
    // the next normal quit of that session removes again.
    std.Io.Dir.cwd().deleteTree(io_mod.getIo(), folder) catch return;
}

fn readAll(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return switch (io_mod.readRegularFile(alloc, path, max_bytes)) {
        // The reader allocated the bytes in `alloc`, so the caller owns them.
        .bytes => |bytes| @constCast(bytes),
        .missing => error.FileNotFound,
        .unreadable, .too_large => error.Unreadable,
    };
}

test "output is appended to the monitor's own file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try append(alloc, home, "sess1", "shell-1", "one\n");
    try append(alloc, home, "sess1", "shell-1", "two\n");
    try append(alloc, home, "sess1", "shell-2", "other\n");
    const path = try filePath(alloc, home, "sess1", "shell-1");
    defer alloc.free(path);
    const bytes = try readAll(alloc, path, 1024);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("one\ntwo\n", bytes);
}

test "a full file rolls over to .log.1 and a new file starts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const chunk = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(chunk);
    @memset(chunk, 'a');
    for (0..4) |_| try append(alloc, home, "sess1", "shell-1", chunk);
    try append(alloc, home, "sess1", "shell-1", "fresh\n");
    const path = try filePath(alloc, home, "sess1", "shell-1");
    defer alloc.free(path);
    const current = try readAll(alloc, path, 1024);
    defer alloc.free(current);
    try std.testing.expectEqualStrings("fresh\n", current);
    const older_path = try alloc.print("{s}.1", .{path});
    defer alloc.free(older_path);
    const older = try readAll(alloc, older_path, 5 * 1024 * 1024);
    defer alloc.free(older);
    try std.testing.expectEqual(@as(usize, max_file_bytes), older.len);
}

test "a name that is not plain names no file, and a folder goes with its session" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidName, filePath(alloc, "/Users/example", "../x", "shell-1"));
    try std.testing.expectError(error.InvalidName, filePath(alloc, "/Users/example", "s", "a/b"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try append(alloc, home, "sess1", "shell-1", "x");
    removeSession(alloc, home, "sess1");
    const path = try filePath(alloc, home, "sess1", "shell-1");
    defer alloc.free(path);
    try std.testing.expectError(error.FileNotFound, readAll(alloc, path, 16));
}
