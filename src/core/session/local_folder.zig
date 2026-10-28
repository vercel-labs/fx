//! The session tree's scratch folder, `~/.proto-fx/local/<root session
//! id>/` (D243). `local://` reads it, browser screenshots land in its
//! `screenshots/` folder (D274), and it is removed with the session.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_paths = @import("session_store_paths.zig");

const Allocator = std.mem.Allocator;

const dir_name = "local";

/// The folder's real path, creating it private when it is missing. Memory
/// comes from `arena`.
pub fn open(arena: Allocator, home: []const u8, root_id: []const u8) ![]const u8 {
    const io = io_mod.getIo();
    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer home_dir.close(io);
    var profile = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.root_dir_name);
    defer profile.close();
    var local = try io_mod.openOrCreateVerifiedPrivateDir(&profile, dir_name);
    defer local.close();
    var session = try io_mod.openOrCreateVerifiedPrivateDir(&local, root_id);
    defer session.close();
    return io_mod.realpathAlloc(arena, try std.Io.Dir.path.join(arena, &.{ home, profile_paths.root_dir_name, dir_name, root_id }));
}

/// Removes session `id`'s folder. True when it is gone or never existed.
pub fn remove(alloc: Allocator, home: []const u8, id: []const u8) bool {
    session_paths.validateSessionId(id) catch return false;
    const io = io_mod.getIo();
    const root = std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, dir_name }) catch return false;
    defer alloc.free(root);
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch |err| return err == error.FileNotFound;
    defer dir.close(io);
    dir.deleteTree(io, id) catch return false;
    return true;
}

test "a session's local folder is made private and removed with it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const path = try open(arena_state.allocator(), home, "abcdefghijkl");
    const shot = try std.Io.Dir.path.join(arena_state.allocator(), &.{ path, "screenshots", "a.jpg" });
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), std.Io.Dir.path.dirname(shot).?);
    try std.Io.Dir.cwd().writeFile(io_mod.getIo(), .{ .sub_path = shot, .data = "jpeg" });
    try std.testing.expect(remove(alloc, home, "abcdefghijkl"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}));
    // Nothing to remove is not a failure; a bad id is refused.
    try std.testing.expect(remove(alloc, home, "abcdefghijkl"));
    try std.testing.expect(!remove(alloc, home, "../x"));
}
