//! An `mremap` for sanitized Linux builds (`-Dsanitize-thread`), which
//! `build.zig` links into each of them in place of libc's.
//!
//! ThreadSanitizer does not intercept `mremap`. When `std.heap.PageAllocator`
//! shrinks a block, or moves one to grow it, the pages it releases keep their
//! access history, so the next thread to use those addresses appears to race
//! with the thread that released them. This `mremap` makes the same change
//! with calls the sanitizer sees: it shrinks with `munmap`, and when a block
//! has to move, it maps a new one, copies, and unmaps the old one.
//!
//! The copy relies on the mapping being private, anonymous, and readable and
//! writable. fx calls `mremap` only through `std.heap.PageAllocator`, whose
//! mappings are. Any other flags go straight to the kernel.
//!
//! libc declares `mremap` variadic and reads a fifth argument only with
//! `MREMAP_FIXED`. On x86_64 and aarch64 Linux, the only targets this is
//! built for, that argument arrives where a fifth named one would, so this
//! takes it as one: Zig 0.17 can't define a variadic function for aarch64.
const std = @import("std");
const linux = std.os.linux;

const Pages = [*]align(std.heap.page_size_min) u8;

export fn mremap(old: ?Pages, old_len: usize, new_len: usize, flags: linux.MREMAP, fixed: ?Pages) callconv(.c) *anyopaque {
    if (old == null or flags.FIXED or flags.DONTUNMAP) {
        return kernelRemap(old, old_len, new_len, flags, if (flags.FIXED) fixed else null);
    }
    const page = std.heap.pageSize();
    const old_size = std.mem.alignForward(usize, old_len, page);
    const new_size = std.mem.alignForward(usize, new_len, page);
    const start = old.?;
    if (new_size == old_size) return @ptrCast(start);
    if (new_size < old_size) {
        if (std.c.munmap(@ptrCast(@alignCast(start + new_size)), old_size - new_size) != 0) return std.c.MAP_FAILED;
        return @ptrCast(start);
    }
    // Growing in place maps only addresses nothing holds, which the
    // sanitizer has already seen released.
    const grown = kernelRemap(start, old_size, new_size, .{}, null);
    if (grown != std.c.MAP_FAILED or !flags.MAYMOVE) return grown;
    const moved = std.c.mmap(null, new_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (moved == std.c.MAP_FAILED) return moved;
    const to: Pages = @ptrCast(@alignCast(moved));
    @memcpy(to[0..old_size], start[0..old_size]);
    _ = std.c.munmap(@ptrCast(start), old_size);
    return moved;
}

fn kernelRemap(old: ?Pages, old_len: usize, new_len: usize, flags: linux.MREMAP, new: ?Pages) *anyopaque {
    const rc = linux.mremap(old, old_len, new_len, flags, new);
    switch (linux.errno(rc)) {
        .SUCCESS => return @ptrFromInt(rc),
        else => |err| {
            std.c._errno().* = @backingInt(err);
            return std.c.MAP_FAILED;
        },
    }
}
