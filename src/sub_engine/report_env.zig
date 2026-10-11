//! The environment entry that tells a terminal's child where its report
//! channel is.
//!
//! The child inherits its end of a socket pair the owner holds the other end
//! of, without close-on-exec, and its environment names it as
//! `SUB_ENGINE_REPORT=<fd>:<device>:<inode>`. The child program must set
//! FD_CLOEXEC on that fd itself before it starts other programs, or they
//! inherit the channel too and can write to the owner. They still inherit
//! the entry, and that fd number may then belong to some other file, so a
//! program checks that the fd is still the named channel before it writes.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

pub const name = "SUB_ENGINE_REPORT";

/// The entry naming `fd`, allocated in `arena`. Null when `fd` cannot be
/// identified.
pub fn entry(arena: Allocator, fd: fd_t) error{OutOfMemory}!?[]const u8 {
    const id = identity(fd) orelse return null;
    return try std.fmt.allocPrint(arena, name ++ "={d}:{d}:{d}", .{ fd, id.dev, id.ino });
}

/// The fd that `value`, the entry's value, names, when that fd is still
/// the channel it names. Null otherwise.
pub fn inheritedFd(value: []const u8) ?fd_t {
    var fields = std.mem.splitScalar(u8, value, ':');
    const fd = std.fmt.parseInt(fd_t, fields.next() orelse return null, 10) catch return null;
    const dev = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const ino = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null or fd < 0) return null;
    const id = identity(fd) orelse return null;
    if (id.dev != dev or id.ino != ino) return null;
    return fd;
}

const Identity = struct { dev: u64, ino: u64 };

fn identity(fd: fd_t) ?Identity {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx = std.mem.zeroes(linux.Statx);
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stx);
            if (linux.errno(rc) != .SUCCESS) return null;
            return .{ .dev = @as(u64, stx.dev_major) << 32 | stx.dev_minor, .ino = stx.ino };
        },
        .macos => {
            var st = std.mem.zeroes(std.c.Stat);
            if (std.c.fstat(fd, &st) != 0) return null;
            return .{ .dev = @as(u32, @bitCast(st.dev)), .ino = st.ino };
        },
        else => @compileError("sub-engine terminals need Linux or macOS"),
    }
}

const testing = std.testing;
const fd_ops = @import("fd.zig");

test "an entry names its pipe and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const pipe = try fd_ops.pipe(.{});
    defer fd_ops.close(pipe.read);
    defer fd_ops.close(pipe.write);
    const other = try fd_ops.pipe(.{});
    defer fd_ops.close(other.read);
    defer fd_ops.close(other.write);

    const text = (try entry(arena_state.allocator(), pipe.write)).?;
    try testing.expect(std.mem.startsWith(u8, text, name ++ "="));
    const value = text[name.len + 1 ..];
    try testing.expectEqual(@as(?fd_t, pipe.write), inheritedFd(value));

    // The same fd number holding another pipe is refused.
    try testing.expect(std.c.dup2(other.write, pipe.write) >= 0);
    try testing.expectEqual(@as(?fd_t, null), inheritedFd(value));

    for ([_][]const u8{ "", "3", "3:1", "x:1:2", "3:1:2:4", "-1:0:0" }) |bad| {
        try testing.expectEqual(@as(?fd_t, null), inheritedFd(bad));
    }
}
