//! Native system URL opener behind the host.UrlOpener contract. Opens a URL
//! in the user's default browser via the platform launcher; shared by
//! authentication and user-consented URL flows.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const native_opener = host.UrlOpener{
    .open_fn = openUrlForHost,
};

fn openUrlForHost(_: ?*anyopaque, alloc: Allocator, url: []const u8) host.UrlOpenError!bool {
    return openUrl(alloc, url);
}

fn openUrl(alloc: Allocator, url: []const u8) Allocator.Error!bool {
    return launchUrl(alloc, url, builtin.os.tag, .{}) == .opened;
}

const LaunchResult = struct {
    term: std.process.Child.Term,
};

const LaunchFn = *const fn (*anyopaque, Allocator, []const []const u8) anyerror!LaunchResult;

const Launcher = struct {
    ctx: *anyopaque = undefined,
    launch: LaunchFn = launchActual,
};

const LaunchOutcome = enum {
    opened,
    failed,
    unsupported,
};

fn launchActual(_: *anyopaque, arena: Allocator, argv: []const []const u8) anyerror!LaunchResult {
    const result = try std.process.run(arena, io_mod.getIo(), .{ .argv = argv });
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);
    return .{ .term = result.term };
}

fn launchUrl(
    alloc: Allocator,
    url: []const u8,
    os_tag: std.Target.Os.Tag,
    launcher: Launcher,
) LaunchOutcome {
    const macos_argv = [_][]const u8{ "open", url };
    const linux_argv = [_][]const u8{ "xdg-open", url };
    const windows_argv = [_][]const u8{ "rundll32.exe", "url.dll,FileProtocolHandler", url };
    const argv: []const []const u8 = switch (os_tag) {
        .windows => &windows_argv,
        .macos => &macos_argv,
        .linux => &linux_argv,
        else => return .unsupported,
    };

    const result = launcher.launch(launcher.ctx, alloc, argv) catch |err| {
        debug_trace.logf("core", "url opener launcher failed err={s}", .{@errorName(err)});
        return .failed;
    };
    switch (result.term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }

    logUnsuccessfulTerm(result.term);
    return .failed;
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("core", "url opener unsuccessful term=exited exit_code={d}", .{code}),
        .signal => |sig| debug_trace.logf("core", "url opener unsuccessful term=signal signal={d}", .{@intFromEnum(sig)}),
        .stopped => |sig| debug_trace.logf("core", "url opener unsuccessful term=stopped signal={d}", .{@intFromEnum(sig)}),
        .unknown => |code| debug_trace.logf("core", "url opener unsuccessful term=unknown status={d}", .{code}),
    }
}

const MockLauncher = struct {
    argv_joined: std.ArrayList(u8) = .empty,
    result: anyerror!LaunchResult = .{ .term = .{ .exited = 0 } },

    fn launch(raw: *anyopaque, alloc: Allocator, argv: []const []const u8) anyerror!LaunchResult {
        const self: *MockLauncher = @ptrCast(@alignCast(raw));
        for (argv, 0..) |arg, i| {
            if (i > 0) try self.argv_joined.append(alloc, ' ');
            try self.argv_joined.appendSlice(alloc, arg);
        }
        return self.result;
    }

    fn launcher(self: *MockLauncher) Launcher {
        return .{ .ctx = self, .launch = launch };
    }

    fn deinit(self: *MockLauncher, alloc: Allocator) void {
        self.argv_joined.deinit(alloc);
    }
};

test "url opener selects the platform launcher argv" {
    const alloc = std.testing.allocator;

    var macos = MockLauncher{};
    defer macos.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .macos, macos.launcher()));
    try std.testing.expectEqualStrings("open http://localhost:3000", macos.argv_joined.items);

    var linux = MockLauncher{};
    defer linux.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .linux, linux.launcher()));
    try std.testing.expectEqualStrings("xdg-open http://localhost:3000", linux.argv_joined.items);

    var windows = MockLauncher{};
    defer windows.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .windows, windows.launcher()));
    try std.testing.expectEqualStrings("rundll32.exe url.dll,FileProtocolHandler http://localhost:3000", windows.argv_joined.items);
}

test "url opener reports unsupported platforms without launching" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, launchUrl(alloc, "http://x", .freebsd, mock.launcher()));
    try std.testing.expectEqualStrings("", mock.argv_joined.items);
}

test "url opener treats nonzero exit, bad terms, and launch errors as failed" {
    const alloc = std.testing.allocator;

    var nonzero = MockLauncher{ .result = .{ .term = .{ .exited = 3 } } };
    defer nonzero.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, nonzero.launcher()));

    var signaled = MockLauncher{ .result = .{ .term = .{ .signal = @enumFromInt(2) } } };
    defer signaled.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, signaled.launcher()));

    var erroring = MockLauncher{ .result = error.SpawnFailed };
    defer erroring.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .linux, erroring.launcher()));
}
