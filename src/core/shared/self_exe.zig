const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

const linux_self_exe = "/proc/self/exe";

/// Path used to spawn another copy of *this* process.
///
/// `zig build` replaces `zig-out/bin/fx` by unlink+rename. The running
/// inode stays alive, but `std.process.executablePathAlloc` realpaths
/// `/proc/self/exe` to the old on-disk name, and the next spawn is
/// `FileNotFound`. Linux `/proc/self/exe` still execs the live inode.
pub fn pathForReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    if (comptime builtin.os.tag == .linux) return alloc.dupe(u8, linux_self_exe);
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

/// Path another process can use to exec this still-running fx.
///
/// Tmux bootstraps and similar scripts run later, so `/proc/self/exe`
/// would be the shell, not fx. `/proc/<pid>/exe` stays on this inode
/// even after the on-disk binary is replaced.
pub fn pathForPeerReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    if (comptime builtin.os.tag == .linux) {
        return std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{std.c.getpid()});
    }
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

fn testProductExe() ?[]const u8 {
    if (comptime !builtin.is_test) return null;
    const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse return null;
    const path = std.mem.sliceTo(path_z, 0);
    return if (path.len == 0) null else path;
}

test "linux re-exec path uses procfs instead of the replaced on-disk name" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    const path = try pathForReexec(alloc);
    defer alloc.free(path);
    if (testProductExe() != null) {
        try std.testing.expect(path.len > 0);
        return;
    }
    try std.testing.expectEqualStrings(linux_self_exe, path);
}
