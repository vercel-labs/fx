const std = @import("std");

/// Overwrite an owned secret before returning its allocation to the allocator.
pub noinline fn zeroAndFree(alloc: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.rawFree(value, .of(u8), @returnAddress());
}

test "zeroAndFree overwrites bytes before release" {
    var buffer: [3]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const backing = fixed.allocator();
    const vtable = std.mem.Allocator.VTable{
        .alloc = backing.vtable.alloc,
        .resize = backing.vtable.resize,
        .remap = backing.vtable.remap,
        .free = std.mem.Allocator.noFree,
    };
    const alloc = std.mem.Allocator{ .ptr = backing.ptr, .vtable = &vtable };
    const value = try alloc.dupe(u8, &.{ 1, 2, 3 });
    zeroAndFree(alloc, value);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &buffer);
}
