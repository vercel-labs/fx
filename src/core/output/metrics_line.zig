//! The `/stats` line: the counters the terminal UI keeps about its own work.
const std = @import("std");
const types = @import("../shared/types.zig");

/// Writes one metrics line into `buf`. Caller owns the buffer.
pub fn write(buf: []u8, metrics: types.Metrics) ![]const u8 {
    return std.mem.print(buf, "ansi_bytes={d}, redraws={d}, debounced_resizes={d}, footer_updates={d}, stream_chunks={d}", .{
        metrics.ansi_bytes,
        metrics.full_redraws,
        metrics.debounced_resizes,
        metrics.footer_line_updates,
        metrics.stream_chunks,
    });
}

test "write renders every counter in a stable order" {
    var buf: [256]u8 = undefined;
    const line = try write(&buf, .{
        .ansi_bytes = 10,
        .full_redraws = 2,
        .debounced_resizes = 3,
        .footer_line_updates = 4,
        .stream_chunks = 5,
    });
    try std.testing.expectEqualStrings(
        "ansi_bytes=10, redraws=2, debounced_resizes=3, footer_updates=4, stream_chunks=5",
        line,
    );
}
