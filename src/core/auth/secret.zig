const std = @import("std");

/// Overwrite an owned secret before returning its allocation to the allocator.
pub noinline fn zeroAndFree(alloc: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.free(value);
}

/// Overwrite an owned secret in place, for buffers whose allocation is released
/// by their owner rather than freed here (a writer's backing buffer, say).
pub noinline fn zero(value: []const u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @constCast(@volatileCast(value)));
}

test "zero overwrites bytes in place and tolerates an empty slice" {
    var value = [_]u8{ 1, 2, 3 };
    zero(value[0..]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &value);
    zero(&.{});
}

test "zeroAndFree overwrites bytes before release" {
    var value = [_]u8{ 1, 2, 3 };
    std.crypto.secureZero(u8, @volatileCast(value[0..]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &value);
}
