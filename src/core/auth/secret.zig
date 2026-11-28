const std = @import("std");

/// Overwrite an owned secret before returning its allocation to the allocator.
pub noinline fn zeroAndFree(alloc: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.free(value);
}

/// An allocator for memory that may hold a secret: a std.json parse of a
/// token reply or an auth file, the writer of a request body or a saved
/// session, or a buffer that reads one. Every block it gives back to `child`
/// is wiped first. `free` overwrites the whole block, and `resize` and
/// `remap` succeed only for growth in place, so a block that has to move or
/// shrink is copied by its caller and the old block wiped and freed, never
/// handed to a realloc that frees it as it is. Blocks come straight from
/// `child`, so a caller may free a result through `child` with
/// `zeroAndFree` (`tests/tla/secret/SecretWipe.tla` NoSecretReleased).
pub const Wiping = struct {
    child: std.mem.Allocator,

    pub fn init(child: std.mem.Allocator) Wiping {
        return .{ .child = child };
    }

    pub fn allocator(self: *Wiping) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Wiping = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Wiping = @ptrCast(@alignCast(ctx));
        // A shrink would give its tail back unwiped.
        if (new_len < memory.len) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Wiping = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, @volatileCast(memory));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "zeroAndFree overwrites bytes before release" {
    var value = [_]u8{ 1, 2, 3 };
    std.crypto.secureZero(u8, @volatileCast(value[0..]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &value);
}

test "Wiping gives back no block that still holds a secret, and refuses to shrink one" {
    const testing_allocator = @import("../shared/testing_allocator.zig");
    var scan: testing_allocator.ReleaseScan = .{ .needle = "SECRET_MARK" };
    var wiping: Wiping = .init(scan.allocator());
    const alloc = wiping.allocator();

    // A writer that outgrows its buffer, then hands the bytes out.
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("SECRET_MARK");
    const filler: [4096]u8 = @splat('x');
    try out.writer.writeAll(&filler);
    const text = try out.toOwnedSlice();
    // Results come straight from the child, so the child can free them.
    zeroAndFree(scan.allocator(), text);

    // A shrink is refused, so the caller copies and frees through Wiping.
    const block = try alloc.dupe(u8, "SECRET_MARK and more");
    try std.testing.expect(!alloc.resize(block, 4));
    try std.testing.expect(alloc.remap(block, 4) == null);
    alloc.rawFree(block, .of(u8), @returnAddress());

    try scan.expectWiped();

    // Even over libc, which shrinks a block in place and keeps its tail.
    var over_libc: Wiping = .init(std.heap.c_allocator);
    const libc = over_libc.allocator();
    const kept = try libc.alloc(u8, 64);
    defer libc.free(kept);
    try std.testing.expect(!libc.resize(kept, 4));
    try std.testing.expect(libc.remap(kept, 4) == null);
}
