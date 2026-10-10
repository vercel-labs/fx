const std = @import("std");

// Centralize generic free paths that Zig would otherwise duplicate at each
// error exit, reducing generated code to one call per cleanup site.

/// Drop-in replacement for `alloc.free(slice)`.
pub fn free(alloc: std.mem.Allocator, memory: anytype) void {
    const info = @typeInfo(@TypeOf(memory)).pointer;
    comptime std.debug.assert(info.size == .slice);
    const bytes: []u8 = @ptrCast(@constCast(std.mem.absorbSentinel(memory)));
    freeErased(
        alloc,
        bytes.ptr,
        bytes.len,
        .fromByteUnits(info.attrs.@"align" orelse @alignOf(info.child)),
        @returnAddress(),
    );
}

/// Drop-in replacement for `list.deinit(alloc)` on an unmanaged array list.
pub fn deinitList(alloc: std.mem.Allocator, list: anytype) void {
    free(alloc, list.allocatedSlice());
    list.* = undefined;
}

/// Drop-in replacement for `arena.deinit()` at cleanup-heavy call sites.
pub noinline fn deinit_arena(arena: std.heap.ArenaAllocator) void {
    arena.deinit();
}

noinline fn freeErased(
    alloc: std.mem.Allocator,
    ptr: [*]u8,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    if (len == 0) return;
    const bytes = ptr[0..len];
    @memset(bytes, undefined);
    alloc.rawFree(bytes, alignment, ret_addr);
}

test "free releases an allocated slice" {
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u64, 16);
    free(alloc, buf);
}

test "free accepts an empty slice" {
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, 0);
    free(alloc, buf);
}

test "deinitList releases list capacity" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(usize) = .empty;
    try list.append(alloc, 7);
    try list.append(alloc, 11);
    deinitList(alloc, &list);
}

test "deinitList on a never-grown list is a no-op" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    deinitList(alloc, &list);
}

test "deinit_arena releases arena allocations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    _ = try arena.allocator().alloc(u8, 16);
    deinit_arena(arena);
}
