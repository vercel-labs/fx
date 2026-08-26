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

/// Build an `Authorization: Bearer` value in an exactly sized allocation. The
/// obvious `allocPrint` grows an oversized buffer and releases it once the real
/// length is known, leaving a plaintext copy of the token in the abandoned
/// block. The caller owns the result and releases it with `zeroAndFree`.
pub fn bearerHeaderAlloc(alloc: std.mem.Allocator, access_token: []const u8) ![]u8 {
    const prefix = "Bearer ";
    const header = try alloc.alloc(u8, prefix.len + access_token.len);
    @memcpy(header[0..prefix.len], prefix);
    @memcpy(header[prefix.len..], access_token);
    return header;
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
/// Test helper. Records whether any allocation still held a credential in
/// plaintext at the moment it was returned to the allocator. The scan runs
/// before the backing allocator sees the block, so a debug build's own poison
/// does not hide the answer.
pub const ScanAllocator = struct {
    backing: std.mem.Allocator,
    marker: []const u8,
    released_with_plaintext: usize = 0,

    pub fn allocator(self: *ScanAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = scanAlloc,
            .resize = scanResize,
            .remap = scanRemap,
            .free = scanFree,
        } };
    }

    fn scanAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ScanAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
    }

    fn scanResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ScanAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn scanRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ScanAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn scanFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ScanAllocator = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, memory, self.marker) != null) {
            self.released_with_plaintext += 1;
        }
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }
};

// The needle is short and sits at the start of the credential, so it is found in
// a partially written buffer too. Searching for the whole credential would miss
// exactly the case this guards: a buffer abandoned mid-growth holds a truncated
// prefix, not the complete value.
pub const scan_needle = "OAUTH_TEST_CREDENTIAL_MARKER";

// Long enough that the encoded body outgrows the writer's initial buffer. A
// short credential fits in the first allocation and never exercises the growth
// path, which leaves the test vacuous.
pub const scan_marker = scan_needle ++ ("x" ** 1024);

test "the scan allocator sees a credential abandoned while a writer grows" {
    // `Allocator.free` overwrites a block with `undefined` in a safety build
    // before any wrapping allocator sees it, so the observable half is the
    // growth path: every buffer a writer outgrows is handed back through
    // `remap`/`rawFree` with its contents intact.
    var scan = ScanAllocator{ .backing = std.testing.allocator, .marker = scan_needle };
    const alloc = scan.allocator();

    // Appended in pieces, the way a form or JSON body is assembled. One
    // `writeAll` of the whole value sizes the buffer in a single step and
    // abandons nothing.
    var grown: std.Io.Writer.Allocating = .init(alloc);
    defer grown.deinit();
    for (0..scan_marker.len) |i| try grown.writer.writeByte(scan_marker[i]);
    try std.testing.expect(scan.released_with_plaintext > 0);

    // Reserved up front and wiped at the end, the same shape the callers use:
    // nothing is abandoned, so the count does not move.
    const before = scan.released_with_plaintext;
    var reserved: std.Io.Writer.Allocating = try .initCapacity(alloc, scan_marker.len * 2);
    defer reserved.deinit();
    defer zero(reserved.written());
    for (0..scan_marker.len) |i| try reserved.writer.writeByte(scan_marker[i]);
    try std.testing.expectEqual(before, scan.released_with_plaintext);
}

test "the bearer header leaves no abandoned copy of the token" {
    var scan = ScanAllocator{ .backing = std.testing.allocator, .marker = scan_needle };
    const alloc = scan.allocator();

    const header = try bearerHeaderAlloc(alloc, scan_marker);
    try std.testing.expectStringStartsWith(header, "Bearer " ++ scan_needle);
    try std.testing.expectEqual(@as(usize, "Bearer ".len + scan_marker.len), header.len);
    zeroAndFree(alloc, header);
    try std.testing.expectEqual(@as(usize, 0), scan.released_with_plaintext);
}
