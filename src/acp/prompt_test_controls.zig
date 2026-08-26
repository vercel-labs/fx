const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const private_file_permissions = io_mod.permissionsFromMode(0o600);

const Controls = struct {
    terminal_ready_path: []const u8,
    reap_ready_path: []const u8,
    release_path: []const u8,
};

pub fn pauseAfterTerminalWrite() void {
    const control = controls() orelse return;
    writeMarker(control.terminal_ready_path, "terminal_response_written") catch return;
    while (!pathExists(control.release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

pub fn noteReapBeforeJoin() void {
    const control = controls() orelse return;
    writeMarker(control.reap_ready_path, "reap_before_join") catch {};
}

fn controls() ?Controls {
    return controlsFromPaths(
        io_mod.getenv("FX_E2E_ACP_PROMPT_TERMINAL_READY"),
        io_mod.getenv("FX_E2E_ACP_PROMPT_REAP_READY"),
        io_mod.getenv("FX_E2E_ACP_PROMPT_RELEASE"),
    );
}

fn controlsFromPaths(
    terminal_ready_path: ?[]const u8,
    reap_ready_path: ?[]const u8,
    release_path: ?[]const u8,
) ?Controls {
    return .{
        .terminal_ready_path = terminal_ready_path orelse return null,
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
