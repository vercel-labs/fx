//! For tests of the locks that `keychain_lock.zig` places: the states a lock
//! file can be in that fx can't take its lock in, such as a stale file a
//! `sudo` run left in `~/.fx` (fx opens a lock file without following a link,
//! only as a regular file, and only when it is private), and the trace lines
//! a lock writes.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

pub const State = enum {
    /// A link to a file that is not there.
    symlink,
    /// A regular file other users can read.
    mode_644,
    /// A folder.
    folder,
    /// A named pipe.
    fifo,
};

pub const all = [_]State{ .symlink, .mode_644, .folder, .fifo };

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// Puts `state` at `name`, a path under `dir`. `error.SkipZigTest` where the
/// platform can't make it.
pub fn plant(dir: std.Io.Dir, name: []const u8, state: State) !void {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) return error.SkipZigTest;
    const io = std.testing.io;
    switch (state) {
        .symlink => try dir.symLink(io, "no-such-file", name, .{}),
        .mode_644 => {
            var file = try dir.createFile(io, name, .{ .permissions = std.Io.File.Permissions.fromMode(0o644) });
            defer file.close(io);
            try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o644));
        },
        .folder => try dir.createDir(io, name, std.Io.File.Permissions.fromMode(0o700)),
        .fifo => {
            const root = try io_mod.dirRealpathAlloc(std.testing.allocator, dir, "");
            defer std.testing.allocator.free(root);
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ root, name }, 0);
            if (mkfifo(path, 0o600) != 0) return error.SkipZigTest;
        },
    }
}

/// Sends fx's trace to `trace.log` under `tmp` until `debug_trace.resetForTest()`.
pub fn traceTo(tmp: std.testing.TmpDir) !void {
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    const path = try std.testing.allocator.print("{s}/trace.log", .{root});
    defer std.testing.allocator.free(path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(std.testing.allocator, path);
}

/// What `traceTo` has collected. The caller frees it.
pub fn readTrace(tmp: std.testing.TmpDir) ![]u8 {
    return tmp.dir.readFileAlloc(std.testing.io, "trace.log", std.testing.allocator, .limited(1 << 16));
}

test "each state is there for fx to find, and none is a private regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (all) |state| {
        const name = @tagName(state);
        try plant(tmp.dir, name, state);
        const stat = try tmp.dir.statFile(std.testing.io, name, .{ .follow_symlinks = false });
        try std.testing.expect(switch (state) {
            .symlink => stat.kind == .sym_link,
            .mode_644 => stat.kind == .file and stat.permissions.toMode() & 0o777 == 0o644,
            .folder => stat.kind == .directory,
            .fifo => stat.kind == .named_pipe,
        });
    }
}
