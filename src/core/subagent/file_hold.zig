//! The file protocol of the subagent test controls
//! (`end_test_controls.zig`, `start_test_controls.zig`). A control holds a
//! slot at one point: it writes `<held>.<n>` for the n-th hold of its kind in
//! the process, with a line that names the child, then waits until
//! `<release>` or `<release>.<n>` exists, for at most a minute. A test that
//! sets the two environment variables of a control finds the marker and lets
//! the slot go when it chooses. Only such tests set them, so the libfx
//! artifacts leave the controls out. A hold can also poll while it waits, so a
//! test can make something happen in the held slot's window (`Poll`,
//! `takeRequest`).
//!
//! A control is off unless every path it needs is set, not empty, and
//! absolute. A relative path would name a place under whatever directory fx
//! runs in, which the workspace can be, and the absolute-path file calls assert
//! on one, so such a variable is ignored (`usablePath`).
const std = @import("std");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

/// The path a test control's variable names, when the control may use it: set,
/// not empty, and absolute. Anything else turns the control off.
pub fn usablePath(raw: ?[]const u8) ?[]const u8 {
    const path = raw orelse return null;
    if (path.len == 0 or !std.Io.Dir.path.isAbsolute(path)) return null;
    return path;
}

/// What a hold does on each turn of its wait: `func` with `context`.
pub const Poll = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque) void,
};

pub const Hold = struct {
    /// The environment variables that name the marker and the release file.
    held_env: []const u8,
    release_env: []const u8,
    count: std.atomic.Value(u32) = .init(0),

    /// Whether a test set both variables to absolute paths.
    pub fn armed(self: *const Hold) bool {
        return usablePath(io_mod.getenv(self.held_env)) != null and usablePath(io_mod.getenv(self.release_env)) != null;
    }

    /// Holds the caller: writes the marker with `contents`, then waits for the
    /// release. A set `cancel` ends the wait early, so a stop or quit never
    /// waits on a hold.
    pub fn wait(self: *Hold, contents: []const u8, cancel: ?*const std.atomic.Value(bool), poll: ?Poll) void {
        const held = usablePath(io_mod.getenv(self.held_env)) orelse return;
        const release = usablePath(io_mod.getenv(self.release_env)) orelse return;
        const n = self.count.fetchAdd(1, .seq_cst) + 1;
        var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
        var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
        writeMarker(marker, contents) catch return;
        const deadline = io_mod.milliTimestamp() + max_hold_ms;
        while (!cancelled(cancel) and !pathExists(release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
            if (poll) |each| each.func(each.context);
            io_mod.sleep(std.time.ns_per_ms);
        }
    }
};

/// Whether a test left a request at `path`. The file is removed, so one
/// request is taken once.
pub fn takeRequest(path: []const u8) bool {
    if (usablePath(path) == null or !pathExists(path)) return false;
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch return false;
    return true;
}

fn cancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.seq_cst);
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

test "a hold whose variables are not set is not armed and waits for nothing" {
    var hold = Hold{ .held_env = "FX_TEST_FILE_HOLD_UNSET_HELD", .release_env = "FX_TEST_FILE_HOLD_UNSET_RELEASE" };
    try std.testing.expect(!hold.armed());
    hold.wait("child=none", null, null);
    try std.testing.expectEqual(@as(u32, 0), hold.count.load(.seq_cst));
}

test "a request file is taken once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "request", .data = "" });
    const path = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "request");
    defer std.testing.allocator.free(path);
    try std.testing.expect(takeRequest(path));
    try std.testing.expect(!takeRequest(path));
}

test "a hold ignores a variable that is empty or not an absolute path" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();
    var hold = Hold{ .held_env = "FX_TEST_FILE_HOLD_HELD", .release_env = "FX_TEST_FILE_HOLD_RELEASE" };
    const cases = [_][2][]const u8{
        .{ "relative/held", "relative/release" },
        .{ "relative/held", "/tmp/fx-hold-release" },
        .{ "/tmp/fx-hold-held", "relative/release" },
        .{ "./held", "./release" },
        .{ "", "" },
        .{ "/tmp/fx-hold-held", "" },
    };
    for (cases) |pair| {
        try environ.put("FX_TEST_FILE_HOLD_HELD", pair[0]);
        try environ.put("FX_TEST_FILE_HOLD_RELEASE", pair[1]);
        try std.testing.expect(!hold.armed());
        // A hold that is off returns at once and writes nothing.
        hold.wait("child=none", null, null);
        try std.testing.expectEqual(@as(u32, 0), hold.count.load(.seq_cst));
    }
    try environ.put("FX_TEST_FILE_HOLD_HELD", "/tmp/fx-hold-held");
    try environ.put("FX_TEST_FILE_HOLD_RELEASE", "/tmp/fx-hold-release");
    try std.testing.expect(hold.armed());
}

test "a request path that is not absolute is never taken" {
    try std.testing.expect(!takeRequest(""));
    try std.testing.expect(!takeRequest("relative/request"));
    try std.testing.expect(usablePath(null) == null);
    try std.testing.expectEqualStrings("/tmp/request", usablePath("/tmp/request").?);
}
