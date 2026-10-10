const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

const Allocator = std.mem.Allocator;

const linux_self_exe = "/proc/self/exe";

/// Returns an owned path that re-execs this process. Linux uses
/// `/proc/self/exe` so replacing the on-disk binary does not break later spawns.
pub fn pathForReexec(alloc: Allocator) ![]u8 {
    if (try testProductExe(alloc)) |path| return path;
    return productionPathForReexec(alloc);
}

fn productionPathForReexec(alloc: Allocator) ![]u8 {
    if (comptime builtin.target.os.tag == .linux) return alloc.dupe(u8, linux_self_exe);
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

/// Returns an owned path another process can use to launch fx. Linux prefers
/// the on-disk path, falling back to `/proc/<pid>/exe` after replacement.
pub fn pathForPeerReexec(alloc: Allocator) ![]u8 {
    if (try testProductExe(alloc)) |path| return path;
    return productionPathForPeerReexec(alloc);
}

fn productionPathForPeerReexec(alloc: Allocator) ![]u8 {
    if (comptime builtin.target.os.tag == .linux) {
        const pid = std.c.getpid();
        if (std.process.executablePathAlloc(io_mod.getIo(), alloc)) |resolved| {
            defer alloc.free(resolved);
            if (onDiskPathIsExecutable(resolved)) return alloc.dupe(u8, resolved);
            debug_trace.logf(
                "self_exe",
                "peer re-exec falling back to /proc/{d}/exe on-disk={s}",
                .{ pid, resolved },
            );
        } else |err| {
            debug_trace.logf(
                "self_exe",
                "peer re-exec falling back to /proc/{d}/exe reason={s}",
                .{ pid, @errorName(err) },
            );
        }
        return alloc.print("/proc/{d}/exe", .{pid});
    }
    const path_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(path_z);
    return alloc.dupe(u8, path_z);
}

fn onDiskPathIsExecutable(path: []const u8) bool {
    if (!std.Io.Dir.path.isAbsolute(path)) return false;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn sameFile(left: []const u8, right: []const u8) !bool {
    var left_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), left, .{});
    defer left_file.close(io_mod.getIo());
    var right_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), right, .{});
    defer right_file.close(io_mod.getIo());
    const left_stat = try left_file.stat(io_mod.getIo());
    const right_stat = try right_file.stat(io_mod.getIo());
    return left_stat.inode == right_stat.inode;
}

/// Returns an owned absolute path to the installed fx binary that
/// `zig build test` launches, or null outside tests.
fn testProductExe(alloc: Allocator) !?[]u8 {
    if (comptime !builtin.is_test) return null;
    return try io_mod.realpathAlloc(alloc, @import("test_paths").product_exe);
}

test "linux re-exec paths name the live inode, not the replaced on-disk file" {
    if (builtin.target.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    // Bypass the test override to cover the Linux production branch.
    const same_process = try productionPathForReexec(alloc);
    defer alloc.free(same_process);
    try std.testing.expectEqualStrings(linux_self_exe, same_process);

    const peer = try productionPathForPeerReexec(alloc);
    defer alloc.free(peer);

    const resolved = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch null;
    defer if (resolved) |owned| alloc.free(owned);
    if (resolved) |on_disk| {
        try std.testing.expect(!std.mem.eql(u8, on_disk, same_process));
        try std.testing.expect(try sameFile(same_process, on_disk));
        if (onDiskPathIsExecutable(on_disk)) {
            try std.testing.expectEqualStrings(on_disk, peer);
        } else {
            const expected_peer = try alloc.print("/proc/{d}/exe", .{std.c.getpid()});
            defer alloc.free(expected_peer);
            try std.testing.expectEqualStrings(expected_peer, peer);
        }
    }
}

test "peer re-exec path prefers a name that outlives this process" {
    if (builtin.target.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    const path = try productionPathForPeerReexec(alloc);
    defer alloc.free(path);
    // Fall back to procfs only after the durable on-disk name disappears.
    if (std.mem.startsWith(u8, path, "/proc/")) {
        const resolved = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch return;
        defer alloc.free(resolved);
        try std.testing.expect(!onDiskPathIsExecutable(resolved));
        return;
    }
    try std.testing.expect(onDiskPathIsExecutable(path));
}

test "on-disk probe rejects a replaced binary so the peer path falls back" {
    if (builtin.target.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir_path);
    const victim = try std.Io.Dir.path.join(alloc, &.{ dir_path, "fx-probe" });
    defer alloc.free(victim);

    {
        var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), victim, .{});
        file.close(io_mod.getIo());
    }
    try std.testing.expect(onDiskPathIsExecutable(victim));

    try std.Io.Dir.cwd().deleteFile(io_mod.getIo(), victim);
    try std.testing.expect(!onDiskPathIsExecutable(victim));

    // Peer paths must be absolute.
    try std.testing.expect(!onDiskPathIsExecutable("fx"));
}
