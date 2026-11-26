const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");
const hold_marker = @import("../core/shared/hold_marker.zig");

const Controls = struct {
    ready_path: []const u8,
    reap_ready_path: []const u8,
    release_path: []const u8,
};

// Only tests set these controls, such as `tests/e2e/acp.test.ts`, so the
// libfx artifacts leave them out.
pub fn pauseAfterTerminalWrite() void {
    pauseAt(terminalControls(), "terminal_response_written");
}

pub fn pauseBeforePermissionInsert() void {
    pauseAt(permissionControls(), "permission_ready");
}

pub fn noteReapBeforeJoin() void {
    if (comptime build_options.libfx) return;
    const control = terminalControls() orelse permissionControls() orelse return;
    // The marker only tells a test that the reap came first, and nothing
    // waits here, so fx goes on when it cannot be written.
    hold_marker.write(control.reap_ready_path, "reap_before_join") catch {};
}

fn pauseAt(maybe_control: ?Controls, marker: []const u8) void {
    if (comptime build_options.libfx) return;
    const control = maybe_control orelse return;
    hold_marker.write(control.ready_path, marker) catch return;
    while (!pathExists(control.release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn terminalControls() ?Controls {
    return controlsFromPaths(
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PROMPT_TERMINAL_READY"),
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PROMPT_REAP_READY"),
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PROMPT_RELEASE"),
    );
}

fn permissionControls() ?Controls {
    return controlsFromPaths(
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PERMISSION_READY"),
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PROMPT_REAP_READY"),
        io_mod.getenvAbsolutePath("FX_TEST_ACP_PERMISSION_RELEASE"),
    );
}

fn controlsFromPaths(
    ready_path: ?[]const u8,
    reap_ready_path: ?[]const u8,
    release_path: ?[]const u8,
) ?Controls {
    return .{
        .ready_path = ready_path orelse return null,
        .reap_ready_path = reap_ready_path orelse return null,
        .release_path = release_path orelse return null,
    };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "prompt terminal controls require every path" {
    try std.testing.expect(controlsFromPaths("terminal", "reap", null) == null);
    try std.testing.expect(controlsFromPaths("terminal", "reap", "release") != null);
}
