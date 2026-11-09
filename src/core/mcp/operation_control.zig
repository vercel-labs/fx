const std = @import("std");

pub fn monotonicMillis(io: std.Io) u64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    if (now.raw.nanoseconds <= 0) return 0;
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}
