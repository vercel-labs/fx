const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

const Controls = struct {
    terminal_ready_path: []const u8,
    reap_ready_path: []const u8,
    release_path: []const u8,
};

// Only the fx binary's ACP tests set these controls
// (`tests/e2e/acp.test.ts`), so the libfx artifacts leave them out.
pub fn pauseAfterTerminalWrite() void {
    if (comptime build_options.libfx) return;
    const control = controls() orelse return;
    writeMarker(control.terminal_ready_path, "terminal_response_written") catch return;
    while (!pathExists(control.release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

/// What a Zig test runs after a request's registry entry is inserted and
/// before the request is written, with the kind of request and its id. A test
/// sets it to cancel in that gap, and puts it back.
pub var before_request_write_hook: ?*const fn (kind: []const u8, request_id: u64) void = null;

/// Holds a request after its registry entry is inserted and before the request
/// is written, so a test can cancel in that gap. Every kind of request passes
/// here: a permission request, an elicitation, a host tool call, and a journal
/// flush. The two paths are set only by the tests of one fx process that sends
/// one request at a time (`tests/e2e/acp.test.ts`,
/// `tests/tla/drivers/acp/child_approval/driver.ts`). The marker names the kind.
pub fn pauseBeforeRequestWrite(kind: []const u8, request_id: u64) void {
    if (before_request_write_hook) |hook| hook(kind, request_id);
    if (comptime build_options.libfx) return;
    const inserted_path = io_mod.getenv("FX_TEST_ACP_REQUEST_INSERTED") orelse return;
    const release_path = io_mod.getenv("FX_TEST_ACP_REQUEST_RELEASE") orelse return;
    writeMarker(inserted_path, kind) catch return;
    while (!pathExists(release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

pub fn noteReapBeforeJoin() void {
    if (comptime build_options.libfx) return;
    const control = controls() orelse return;
    writeMarker(control.reap_ready_path, "reap_before_join") catch {};
}

fn controls() ?Controls {
    return controlsFromPaths(
        io_mod.getenv("FX_TEST_ACP_PROMPT_TERMINAL_READY"),
        io_mod.getenv("FX_TEST_ACP_PROMPT_REAP_READY"),
        io_mod.getenv("FX_TEST_ACP_PROMPT_RELEASE"),
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
