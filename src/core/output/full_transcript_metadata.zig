const std = @import("std");
const local_time = @import("../shared/local_time.zig");

pub const Kind = enum {
    prompt,
    response,
    tool,
    task,
    issue,
    notice,
    error_notice,
    usage,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .prompt => "Prompt",
            .response => "Response",
            .tool => "Tool",
            .task => "Task",
            .issue => "Issue",
            .notice => "Notice",
            .error_notice => "Error",
            .usage => "Usage",
        };
    }
};

/// Formats `<local date and time> <zone> · <kind>` into `buf`. Returns null
/// for timestamps outside the supported range or when `buf` is too small.
pub fn formatHeader(
    buf: []u8,
    timestamp_ms: i64,
    kind: Kind,
) ?[]const u8 {
    if (timestamp_ms <= 0) return null;
    const reading = local_time.local(timestamp_ms) orelse return null;
    return std.mem.print(buf, "{f} · {s}", .{ reading, kind.label() }) catch null;
}

test "full transcript metadata formats an entry header in local time" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2024-01-02 03:04:05.006 UTC · Prompt",
        formatHeader(&buf, 1_704_164_645_006, .prompt).?,
    );
    local_time.test_zone = .{ .offset_s = -5 * 3600, .name = "EST" };
    defer local_time.test_zone = .utc;
    try std.testing.expectEqualStrings(
        "2024-01-01 22:04:05.006 EST · Tool",
        formatHeader(&buf, 1_704_164_645_006, .tool).?,
    );
}

test "full transcript metadata rejects unsupported timestamps" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(formatHeader(&buf, 0, .response) == null);
    try std.testing.expect(formatHeader(&buf, -1, .tool) == null);
    try std.testing.expect(formatHeader(&buf, local_time.max_timestamp_ms + 1, .tool) == null);
}
