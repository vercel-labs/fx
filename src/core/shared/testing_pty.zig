//! A pseudo-terminal for tests that need a real terminal behind a descriptor:
//! one that is live, one whose other side closed, or, on macOS, one the system
//! revoked, and the other descriptors those tests lean on. Import it only from
//! test blocks.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const supported = switch (builtin.target.os.tag) {
    .linux,
    .macos,
    .freebsd,
    .netbsd,
    .openbsd,
    => true,
    else => false,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
/// macOS: every open descriptor for the terminal at `path` stops working.
extern "c" fn revoke(path: [*:0]const u8) c_int;

/// A descriptor number no process has open.
pub const closed_fd: std.posix.fd_t = std.math.maxInt(std.posix.fd_t);

pub const TestPty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    pub fn open() !TestPty {
        const flags = std.posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        };
        const master_fd = posix_openpt(@bitCast(flags));
        if (master_fd < 0) return error.PtyUnavailable;
        errdefer closeFd(master_fd);

        if (grantpt(master_fd) != 0) return error.PtyUnavailable;
        if (unlockpt(master_fd) != 0) return error.PtyUnavailable;
        const slave_name = ptsname(master_fd) orelse return error.PtyUnavailable;
        const slave_fd = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, flags, 0);
        return .{ .master = master_fd, .slave = slave_fd };
    }

    pub fn close(self: TestPty) void {
        closeFd(self.master);
        closeFd(self.slave);
    }

    /// Flips ECHO on the slave and returns the settings from before the flip,
    /// so a test can tell whether a later restore put them back.
    pub fn flipEcho(self: TestPty) !std.posix.termios {
        const original = try io_mod.tcgetattr(self.slave);
        var flipped = original;
        flipped.lflag.ECHO = !original.lflag.ECHO;
        try io_mod.tcsetattr(self.slave, .NOW, flipped);
        return original;
    }

    /// Revokes the terminal, as macOS does when its window goes away: every
    /// open descriptor for it, `slave` included, stops working.
    pub fn revokeSlave(self: TestPty) !void {
        const slave_name = ptsname(self.master) orelse return error.PtyUnavailable;
        if (revoke(slave_name) != 0) return error.RevokeFailed;
    }
};

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

/// A pipe that already holds `bytes` and whose write end is closed: reads
/// return the bytes and then 0, as a terminal at end of input does. The caller
/// closes the returned read end.
pub fn pipeAtEndOfInput(bytes: []const u8) !std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    errdefer closeFd(fds[0]);
    defer closeFd(fds[1]);
    if (bytes.len > 0 and std.c.write(fds[1], bytes.ptr, bytes.len) != bytes.len) return error.PipeFailed;
    return fds[0];
}
