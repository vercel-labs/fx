const std = @import("std");
const builtin = @import("builtin");

var wrapped_vtable: std.Io.VTable = undefined;
var original_vtable: ?*const std.Io.VTable = null;
var main_thread_id: std.Thread.Id = undefined;

/// Prevent SIGWINCH from interrupting a background IP connect. Zig 0.16
/// retries connect after EINTR, which can return EISCONN if it completed.
pub fn wrap(original: std.Io) std.Io {
    if (original_vtable) |vtable| {
        std.debug.assert(vtable == original.vtable);
    } else {
        main_thread_id = std.Thread.getCurrentId();
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.netConnectIp = connectIp;
        original_vtable = original.vtable;
    }
    return .{ .userdata = original.userdata, .vtable = &wrapped_vtable };
}

const ResizeGuard = struct {
    old_mask: std.posix.sigset_t = undefined,
    active: bool = false,

    fn init() ResizeGuard {
        if (std.Thread.getCurrentId() == main_thread_id) return .{};
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, .WINCH);
        var guard: ResizeGuard = .{};
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, &guard.old_mask);
        guard.active = true;
        return guard;
    }

    fn deinit(self: *ResizeGuard) void {
        if (self.active) std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.old_mask, null);
    }
};

fn connectIp(
    userdata: ?*anyopaque,
    address: *const std.Io.net.IpAddress,
    options: std.Io.net.IpAddress.ConnectOptions,
) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
    var guard = ResizeGuard.init();
    defer guard.deinit();
    return original_vtable.?.netConnectIp(userdata, address, options);
}

fn noOpResizeHandler(_: std.posix.SIG) callconv(.c) void {}

test "background connect masks resize during a blocking syscall and restores the mask" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    main_thread_id = std.Thread.getCurrentId();
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = noOpResizeHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, &action, &old_action);
    defer std.posix.sigaction(.WINCH, &old_action, null);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const State = struct {
        read_fd: std.c.fd_t,
        pthread: std.c.pthread_t = undefined,
        entered: std.atomic.Value(bool) = .init(false),
        masked: bool = false,
        restored: bool = false,
        read_result: isize = -1,

        fn run(self: *@This()) void {
            var guard = ResizeGuard.init();
            var current: std.posix.sigset_t = undefined;
            std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &current);
            self.masked = std.posix.sigismember(&current, .WINCH);
            self.pthread = std.c.pthread_self();
            self.entered.store(true, .release);
            var byte: [1]u8 = undefined;
            self.read_result = std.c.read(self.read_fd, &byte, 1);
            guard.deinit();
            std.posix.sigprocmask(std.posix.SIG.BLOCK, null, &current);
            self.restored = !std.posix.sigismember(&current, .WINCH);
        }
    };
    var state: State = .{ .read_fd = fds[0] };
    const thread = try std.Thread.spawn(.{}, State.run, .{&state});
    var joined = false;
    defer if (!joined) {
        _ = std.c.write(fds[1], "x", 1);
        thread.join();
    };
    while (!state.entered.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .real);
    _ = std.c.pthread_kill(state.pthread, .WINCH);
    try std.testing.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .real);
    _ = std.c.write(fds[1], "x", 1);
    thread.join();
    joined = true;
    try std.testing.expect(state.masked);
    try std.testing.expect(state.restored);
    try std.testing.expectEqual(@as(isize, 1), state.read_result);
}
