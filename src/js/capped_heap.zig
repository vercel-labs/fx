//! The allocator QuickJS runs on. Every block comes from a Zig allocator, and
//! the total is capped, so one program cannot take more than its share of the
//! process's memory.
//!
//! QuickJS enforces its own heap limit, but it counts only the blocks it
//! hands out, not the 4 KiB arenas it carves small blocks from. This cap
//! counts everything fx gives it, so it still holds when the program's
//! allocation pattern leaves those arenas nearly empty.

const std = @import("std");
const qjs = @import("quickjs.zig");

pub const CappedHeap = struct {
    /// Supplies every block. A runtime calls it from one thread at a time.
    backing: std.mem.Allocator,
    /// Most bytes the heap may hold at once, headers included.
    limit_bytes: usize,
    /// Bytes held now, headers included. Never above `limit_bytes`.
    used_bytes: usize = 0,

    /// Pass with a `*CappedHeap` as the opaque pointer to `JS_NewRuntime2`.
    /// The heap must outlive the runtime.
    pub const functions: qjs.MallocFunctions = .{
        .js_calloc = calloc,
        .js_malloc = malloc,
        .js_free = free,
        .js_realloc = realloc,
        .js_malloc_usable_size = usableSize,
    };

    fn allocate(heap: *CappedHeap, size: usize) ?[*]u8 {
        if (size == 0) return null;
        const total = std.math.add(usize, size, header_bytes) catch return null;
        if (total > heap.limit_bytes - heap.used_bytes) return null;
        const base = heap.backing.rawAlloc(total, alignment, @returnAddress()) orelse return null;
        writeSize(base, size);
        heap.used_bytes += total;
        return base + header_bytes;
    }

    fn release(heap: *CappedHeap, block: Block) void {
        const total = block.size + header_bytes;
        std.debug.assert(total <= heap.used_bytes);
        heap.backing.rawFree(block.base[0..total], alignment, @returnAddress());
        heap.used_bytes -= total;
    }

    fn resize(heap: *CappedHeap, block: Block, size: usize) ?[*]u8 {
        const old_total = block.size + header_bytes;
        const new_total = std.math.add(usize, size, header_bytes) catch return null;
        if (new_total > old_total and new_total - old_total > heap.limit_bytes - heap.used_bytes) return null;
        if (heap.backing.rawRemap(block.base[0..old_total], alignment, new_total, @returnAddress())) |base| {
            writeSize(base, size);
            heap.used_bytes = heap.used_bytes - old_total + new_total;
            return base + header_bytes;
        }
        // The backing allocator can't resize in place; move the block. Both
        // copies count against the cap until the old one is released.
        const moved = heap.allocate(size) orelse return null;
        const kept = @min(size, block.size);
        @memcpy(moved[0..kept], (block.base + header_bytes)[0..kept]);
        heap.release(block);
        return moved;
    }
};

/// Room before each block for its size. 16 bytes keeps the caller's bytes as
/// aligned as `malloc`'s on the targets fx builds for.
const header_bytes = 16;
const alignment: std.mem.Alignment = .@"16";

comptime {
    std.debug.assert(header_bytes >= @sizeOf(usize));
    std.debug.assert(header_bytes % alignment.toByteUnits() == 0);
}

/// A block this heap handed out: where it starts, header included, and the
/// size the caller asked for.
const Block = struct {
    base: [*]align(16) u8,
    size: usize,
};

fn writeSize(base: [*]u8, size: usize) void {
    const slot: *usize = @ptrCast(@alignCast(base));
    slot.* = size;
}

fn blockOf(ptr: *const anyopaque) Block {
    const user: [*]const u8 = @ptrCast(ptr);
    const base: [*]align(16) u8 = @ptrCast(@alignCast(@constCast(user - header_bytes)));
    const slot: *const usize = @ptrCast(base);
    return .{ .base = base, .size = slot.* };
}

fn heapOf(@"opaque": ?*anyopaque) *CappedHeap {
    return @ptrCast(@alignCast(@"opaque".?));
}

fn malloc(@"opaque": ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return heapOf(@"opaque").allocate(size);
}

fn calloc(@"opaque": ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    const bytes = std.math.mul(usize, count, size) catch return null;
    const ptr = heapOf(@"opaque").allocate(bytes) orelse return null;
    @memset(ptr[0..bytes], 0);
    return ptr;
}

fn free(@"opaque": ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    heapOf(@"opaque").release(blockOf(ptr orelse return));
}

/// C `realloc`: a null pointer allocates, a zero size frees, and a failure
/// returns null and leaves the old block in place.
fn realloc(@"opaque": ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const heap = heapOf(@"opaque");
    const old = ptr orelse return heap.allocate(size);
    if (size == 0) {
        heap.release(blockOf(old));
        return null;
    }
    return heap.resize(blockOf(old), size);
}

/// The size the caller asked for. QuickJS's heap limit counts large blocks
/// with this, so it must never report 0 for a live block.
fn usableSize(ptr: ?*const anyopaque) callconv(.c) usize {
    return blockOf(ptr orelse return 0).size;
}

const testing = std.testing;

test "the capped heap hands out aligned blocks and returns every byte" {
    var heap: CappedHeap = .{ .backing = testing.allocator, .limit_bytes = 1 << 20 };
    const h: ?*anyopaque = &heap;

    const a = malloc(h, 24) orelse return error.TestUnexpectedResult;
    try testing.expect(@intFromPtr(a) % 16 == 0);
    try testing.expectEqual(@as(usize, 24), usableSize(a));
    const b = calloc(h, 10, 8) orelse return error.TestUnexpectedResult;
    const zeroed: [*]const u8 = @ptrCast(b);
    for (zeroed[0..80]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(usize, 24 + 80 + 2 * header_bytes), heap.used_bytes);

    free(h, a);
    free(h, b);
    free(h, null);
    try testing.expectEqual(@as(usize, 0), heap.used_bytes);
}

test "the capped heap refuses a block past its limit and keeps counting" {
    var heap: CappedHeap = .{ .backing = testing.allocator, .limit_bytes = 1024 };
    const h: ?*anyopaque = &heap;

    try testing.expect(malloc(h, 1024) == null);
    try testing.expect(malloc(h, 0) == null);
    try testing.expect(calloc(h, std.math.maxInt(usize), 2) == null);
    try testing.expect(malloc(h, std.math.maxInt(usize)) == null);
    try testing.expectEqual(@as(usize, 0), heap.used_bytes);

    const kept = malloc(h, 1024 - header_bytes) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(heap.limit_bytes, heap.used_bytes);
    try testing.expect(malloc(h, 1) == null);
    free(h, kept);
    try testing.expectEqual(@as(usize, 0), heap.used_bytes);
}

test "the capped heap reallocates like C and keeps the block on failure" {
    var heap: CappedHeap = .{ .backing = testing.allocator, .limit_bytes = 4096 };
    const h: ?*anyopaque = &heap;

    const first = realloc(h, null, 8) orelse return error.TestUnexpectedResult;
    const bytes: [*]u8 = @ptrCast(first);
    @memcpy(bytes[0..8], "fx-heap!");

    const grown = realloc(h, first, 1000) orelse return error.TestUnexpectedResult;
    const grown_bytes: [*]const u8 = @ptrCast(grown);
    try testing.expectEqualStrings("fx-heap!", grown_bytes[0..8]);
    try testing.expectEqual(@as(usize, 1000), usableSize(grown));
    try testing.expectEqual(@as(usize, 1000 + header_bytes), heap.used_bytes);

    try testing.expect(realloc(h, grown, 8192) == null);
    try testing.expectEqual(@as(usize, 1000), usableSize(grown));
    try testing.expectEqualStrings("fx-heap!", grown_bytes[0..8]);

    const shrunk = realloc(h, grown, 4) orelse return error.TestUnexpectedResult;
    const shrunk_bytes: [*]const u8 = @ptrCast(shrunk);
    try testing.expectEqualStrings("fx-h", shrunk_bytes[0..4]);
    try testing.expectEqual(@as(usize, 4 + header_bytes), heap.used_bytes);

    try testing.expect(realloc(h, shrunk, 0) == null);
    try testing.expectEqual(@as(usize, 0), heap.used_bytes);
}
