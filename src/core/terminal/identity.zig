const std = @import("std");
const builtin = @import("builtin");

/// Stable local profile identity used only inside private terminal authority.
pub fn profileUser(buffer: *[64]u8) ?[]const u8 {
    if (comptime builtin.target.os.tag == .macos or builtin.target.os.tag == .linux) {
        return std.mem.print(buffer, "uid-{d}", .{std.c.getuid()}) catch null;
    }
    return null;
}

test "profile identity is available exactly on supported terminal hosts" {
    var buffer: [64]u8 = undefined;
    const value = profileUser(&buffer);
    if (comptime builtin.target.os.tag == .macos or builtin.target.os.tag == .linux) {
        try std.testing.expect(value != null);
        try std.testing.expect(std.mem.startsWith(u8, value.?, "uid-"));
    } else {
        try std.testing.expect(value == null);
    }
}
