const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const session_log = @import("../core/session/session_log.zig");

const private_file_permissions = @import("../core/shared/io.zig").permissionsFromMode(0o600);

pub fn logOptions() session_log.Options {
    return logOptionsFromEnv(
        io_mod.getenv("FX_E2E_SESSION_BOUNDARY"),
        io_mod.getenv("FX_E2E_SESSION_BOUNDARY_READY"),
    );
}

fn logOptionsFromEnv(
    boundary: ?[]const u8,
    ready_path: ?[]const u8,
) session_log.Options {
    _ = boundary orelse return .{};
    _ = ready_path orelse return .{};
    return .{
        .test_controls = .{ .boundary_fn = pauseAtRequestedBoundary },
    };
}

fn pauseAtRequestedBoundary(
    _: ?*anyopaque,
    point: session_log.Boundary,
) !void {
    const requested = io_mod.getenv("FX_E2E_SESSION_BOUNDARY") orelse return;
    if (!std.mem.eql(u8, requested, @tagName(point))) return;

    if (io_mod.getenv("FX_E2E_SESSION_BOUNDARY_READY")) |path| {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
            .truncate = true,
            .permissions = private_file_permissions,
        });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), @tagName(point));
        try file.sync(io_mod.getIo());
    }

    while (true) io_mod.sleep(std.time.ns_per_s);
}

test "session boundary fault injection requires ready path" {
    const options = logOptionsFromEnv("after_event_append", null);
    try std.testing.expect(options.test_controls.boundary_fn == null);
}
