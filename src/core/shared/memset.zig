//! The memset the fx executable links.
//!
//! Zig 0.16's compiler_rt memset stores one byte per loop iteration, and the
//! executable links it instead of the C library's. Safe builds call memset to
//! fill every `undefined` buffer: a `PATH_MAX` buffer for each file system
//! call and the new memory of each allocation. That loop executed about two
//! thirds of the instructions in `fx status --json` and `fx sessions --json`.
//! Upstream tracks this as https://codeberg.org/ziglang/zig/issues/32091.
//! Delete this file once the pinned Zig's memset stores more than one byte per
//! iteration.
//!
//! This memset stores 32 bytes at a time. Only Linux executables export it.
//! On macOS, system calls dominate the same commands, and the macOS arm64
//! PGSO build links compiler_rt's object, where a second strong memset is a
//! duplicate symbol. The WASM surfaces and the Node-API addon also keep the
//! toolchain's memset.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.output_mode == .Exe and builtin.os.tag == .linux) {
        @export(&memset, .{ .name = "memset", .linkage = .strong });
    }
}

fn memset(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len != 0) fill(dest.?, @truncate(@as(c_uint, @bitCast(c))), len);
    return dest;
}

const Chunk = @Vector(32, u8);

// Every store is volatile so LLVM cannot turn these loops back into a call to
// memset, which would recurse into this function.
fn fill(dest: [*]u8, byte: u8, len: usize) void {
    @setRuntimeSafety(false);
    if (len < @sizeOf(Chunk)) {
        for (0..len) |i| {
            const slot: *volatile u8 = &dest[i];
            slot.* = byte;
        }
        return;
    }
    const chunk: Chunk = @splat(byte);
    var offset: usize = 0;
    while (len - offset > @sizeOf(Chunk)) : (offset += @sizeOf(Chunk)) {
        const slot: *align(1) volatile Chunk = @ptrCast(dest + offset);
        slot.* = chunk;
    }
    // The last chunk ends at `len` and may overlap bytes already written.
    const last: *align(1) volatile Chunk = @ptrCast(dest + (len - @sizeOf(Chunk)));
    last.* = chunk;
}

test "memset fills exactly the requested bytes at every length and alignment" {
    const guard: u8 = 0x11;
    const value: u8 = 0xa5;
    var buf: [64 + 3 * @sizeOf(Chunk) + 8]u8 = undefined;
    for (0..64) |offset| {
        for (0..3 * @sizeOf(Chunk) + 2) |len| {
            for (&buf) |*b| b.* = guard;
            const start: [*]u8 = buf[offset..].ptr;
            try std.testing.expectEqual(@as(?[*]u8, start), memset(start, value, len));
            for (buf, 0..) |b, i| {
                const want = if (i >= offset and i < offset + len) value else guard;
                try std.testing.expectEqual(want, b);
            }
        }
    }
}

test "memset uses only the low byte of its value" {
    var buf: [40]u8 = @splat(0);
    _ = memset(&buf, 0x1ff, buf.len);
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xff), b);
    buf = @splat(0);
    _ = memset(&buf, -2, 3);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xfe, 0xfe, 0 }, buf[0..4]);
}

test "memset accepts a null destination with zero length" {
    try std.testing.expectEqual(@as(?[*]u8, null), memset(null, 0, 0));
}
