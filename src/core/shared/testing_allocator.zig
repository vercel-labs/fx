//! Allocator for tests that depend on a repeatable allocation sequence.

const std = @import("std");

/// `std.testing.allocator` without in-place resizing.
///
/// `std.heap.SafeAllocator` never reuses memory, so whether a small allocation
/// grows in place depends on how full its bucket is, which differs between
/// otherwise identical runs. Refusing every resize makes each growth allocate,
/// copy, and free, so the allocation sequence depends only on the code under
/// test. Use it as the backing allocator for
/// `std.testing.checkAllAllocationFailures` and for allocation-count
/// comparisons.
pub const no_resize: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}

test "no_resize refuses in-place growth" {
    const memory = try no_resize.alloc(u8, 4);
    defer no_resize.free(memory);
    try std.testing.expect(!no_resize.resize(memory, 8));
    try std.testing.expect(no_resize.remap(memory, 8) == null);
}

/// `std.testing.allocator` that looks at each block as it is given back and
/// counts the ones that still hold `needle`, such as a token the code under
/// test must wipe first. It never resizes a block in place, and `remap`
/// moves the block the way libc's realloc can, giving back the old block as
/// it is, so every growth gives back a block for it to look at.
pub const ReleaseScan = struct {
    needle: []const u8,
    /// Blocks given back.
    released: usize = 0,
    /// Blocks given back that still held `needle`.
    holding: usize = 0,

    pub fn allocator(self: *ReleaseScan) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = scanRemap,
            .free = scanFree,
        } };
    }

    /// Fails unless blocks were given back and none of them held `needle`.
    pub fn expectWiped(self: *const ReleaseScan) !void {
        try std.testing.expect(self.released > 0);
        try std.testing.expectEqual(@as(usize, 0), self.holding);
    }

    fn look(self: *ReleaseScan, memory: []const u8) void {
        self.released += 1;
        if (std.mem.find(u8, memory, self.needle) != null) self.holding += 1;
    }

    fn scanRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ReleaseScan = @ptrCast(@alignCast(ctx));
        const moved = std.testing.allocator.rawAlloc(new_len, alignment, ret_addr) orelse return null;
        const kept = @min(memory.len, new_len);
        @memcpy(moved[0..kept], memory[0..kept]);
        self.look(memory);
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
        return moved;
    }

    fn scanFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ReleaseScan = @ptrCast(@alignCast(ctx));
        self.look(memory);
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
    }
};

test "ReleaseScan counts the blocks given back that still hold the needle" {
    var scan: ReleaseScan = .{ .needle = "needle" };
    const a = scan.allocator();
    const kept = try a.dupe(u8, "a needle");
    a.rawFree(kept, .of(u8), @returnAddress());
    const wiped = try a.dupe(u8, "a needle");
    @memset(wiped, 0);
    a.rawFree(wiped, .of(u8), @returnAddress());
    const grown = try a.dupe(u8, "a needle");
    try std.testing.expect(!a.resize(grown, 64));
    const moved = a.remap(grown, 64).?;
    @memset(moved, 0);
    a.rawFree(moved, .of(u8), @returnAddress());
    try std.testing.expectEqual(@as(usize, 4), scan.released);
    try std.testing.expectEqual(@as(usize, 2), scan.holding);
}
