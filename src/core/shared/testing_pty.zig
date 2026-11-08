//! A pseudo-terminal for tests that need a real terminal behind a descriptor:
//! one that is live, one whose other side closed, or, on macOS, one the system
//! revoked. Import it only from test blocks.
const std = @import("std");
const builtin = @import("builtin");

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
