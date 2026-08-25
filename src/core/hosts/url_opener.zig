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
    var macos_argv = [_][]const u8{ "open", url };
    var linux_argv = [_][]const u8{ "xdg-open", url };
    switch (os_tag) {
        .macos => {
            const result = launcher.launch(launcher.ctx, alloc, &macos_argv) catch |err| {
                debug_trace.logf("core", "url opener launcher failed err={s}", .{@errorName(err)});
                return .failed;
            };
            return outcomeFromTerm(result.term);
        },
        .linux => {
            const result = launcher.launch(launcher.ctx, alloc, &linux_argv) catch |err| {
                debug_trace.logf("core", "url opener launcher failed err={s}", .{@errorName(err)});
                return .failed;
            };
            return outcomeFromTerm(result.term);
        },
        .windows => return launchUrlWindows(alloc, url),
        else => return .unsupported,
    }
}

fn outcomeFromTerm(term: std.process.Child.Term) LaunchOutcome {
    switch (term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }
    logUnsuccessfulTerm(term);
    return .failed;
}

fn launchUrlWindows(alloc: Allocator, url: []const u8) LaunchOutcome {
    // Use ShellExecuteW(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL). The
    // verb "open" resolves to the user's default browser via the shell's
    // association table. We link against shell32 in build.zig so the call
    // resolves at link time.
    const url_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, url) catch return .failed;
    defer alloc.free(url_w);
    // Build a UTF-16LE "open" verb in-place. The buffer is small and
    // lives for the duration of this call, which is bounded by the
    // ShellExecuteW return value (synchronous).
    var verb_buf: [5]u16 = .{ 'o', 'p', 'e', 'n', 0 };
    const SW_SHOWNORMAL: c_int = 1;
    const verb_ptr: [*:0]const u16 = @ptrCast(&verb_buf);
    const result = ShellExecuteW(null, verb_ptr, url_w.ptr, null, null, SW_SHOWNORMAL);
    // ShellExecuteW returns an HINSTANCE with a value > 32 on success.
    if (@intFromPtr(result) <= 32) {
        debug_trace.logf(
            "core",
            "url opener ShellExecuteW failed err={d}",
            .{@intFromPtr(result)},
        );
        return .failed;
    }
    return .opened;
}

// Win32 ShellExecuteW is declared in <shellapi.h>. The stdlib does not
// re-export it, so we declare the prototype here. shell32.dll is added to
// the link line in build.zig.
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.c) ?*anyopaque;

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
}

test "url opener reports unsupported platforms without launching" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, launchUrl(alloc, "http://x", .windows, mock.launcher()));
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
