const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

const Controls = struct {
    ready_path: []const u8,
    reap_ready_path: []const u8,
    release_path: []const u8,
};

// Only the fx binary's ACP tests set these controls
// (`tests/e2e/acp.test.ts`), so the libfx artifacts leave them out.
pub fn pauseAfterTerminalWrite() void {
    pauseAt(terminalControls(), "terminal_response_written");
}

pub fn pauseBeforePermissionInsert() void {
    pauseAt(permissionControls(), "permission_ready");
}

pub fn noteReapBeforeJoin() void {
    if (comptime build_options.libfx) return;
    const control = terminalControls() orelse permissionControls() orelse return;
    writeMarker(control.reap_ready_path, "reap_before_join") catch {};
}

fn pauseAt(maybe_control: ?Controls, marker: []const u8) void {
    if (comptime build_options.libfx) return;
    const control = maybe_control orelse return;
    writeMarker(control.ready_path, marker) catch return;
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

fn writeMarker(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    try file.sync(io_mod.getIo());
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "prompt terminal controls require every path" {
    try std.testing.expect(controlsFromPaths("terminal", "reap", null) == null);
    try std.testing.expect(controlsFromPaths("terminal", "reap", "release") != null);
}
