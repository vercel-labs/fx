const std = @import("std");

// Share one stable sort across element types to avoid duplicating generic code.
// Runs of `run_length` are sorted by insertion, then merged bottom-up through
// a stack buffer. Only those inner loops, which compare elements, are
// compiled per type, so comparisons inline as they do in std.mem.sort; the
// schedule, the buffer, and the fallback are shared. A merge whose runs are
// both larger than the buffer falls back to in-place SymMerge (Kim and
// Kutzner, 2004), whose smaller merges and rotations use the buffer again.

/// Byte order of two strings, as a `sort` comparator.
pub fn lessThanBytes(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Drop-in replacement for std.mem.sort: stable, in place, same signature.
pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    if (@sizeOf(T) == 0) return;
    if (items.len < 2) return;
    const Ctx = @TypeOf(context);
    const thunks = struct {
        fn userCtx(user_ctx: *const anyopaque) Ctx {
            if (comptime @sizeOf(Ctx) == 0) return zeroBitValue(Ctx);
            return @as(*const Ctx, @ptrCast(@alignCast(user_ctx))).*;
        }

        fn typed(base: [*]u8) [*]T {
            return @ptrCast(@alignCast(base));
        }

        fn less(user_ctx: *const anyopaque, lhs: *const anyopaque, rhs: *const anyopaque) bool {
            const lhs_elem: *const T = @ptrCast(@alignCast(lhs));
            const rhs_elem: *const T = @ptrCast(@alignCast(rhs));
            return lessThanFn(userCtx(user_ctx), lhs_elem.*, rhs_elem.*);
        }

        fn insertion(user_ctx: *const anyopaque, base: [*]u8, len: usize) void {
            const ctx = userCtx(user_ctx);
            const elems = typed(base);
            var i: usize = 1;
            while (i < len) : (i += 1) {
                const item = elems[i];
                // Stops at the first element not greater than the item, which
                // keeps equal elements in their original order.
                var j = i;
                while (j > 0 and lessThanFn(ctx, item, elems[j - 1])) : (j -= 1) {
                    elems[j] = elems[j - 1];
                }
                elems[j] = item;
            }
        }

        fn mergeFromLeft(user_ctx: *const anyopaque, base: [*]u8, a: usize, m: usize, b: usize, buf: [*]u8) void {
            const ctx = userCtx(user_ctx);
            const elems = typed(base);
            const tmp = typed(buf);
            const left_len = m - a;
            @memcpy(tmp[0..left_len], elems[a..m]);
            var left: usize = 0;
            var right = m;
            var out = a;
            while (left < left_len and right < b) : (out += 1) {
                if (lessThanFn(ctx, elems[right], tmp[left])) {
                    elems[out] = elems[right];
                    right += 1;
                } else {
                    elems[out] = tmp[left];
                    left += 1;
                }
            }
            @memcpy(elems[out..][0 .. left_len - left], tmp[left..left_len]);
        }

        /// Merges each pair of `width`-long runs of `source` into `dest`.
        fn mergePass(user_ctx: *const anyopaque, source: [*]u8, dest: [*]u8, len: usize, width: usize) void {
            const ctx = userCtx(user_ctx);
            const src = typed(source);
            const dst = typed(dest);
            var start: usize = 0;
            while (start < len) : (start += 2 * width) {
                const m = @min(start + width, len);
                const b = @min(start + 2 * width, len);
                var left = start;
                var right = m;
                var out = start;
                while (left < m and right < b) : (out += 1) {
                    if (lessThanFn(ctx, src[right], src[left])) {
                        dst[out] = src[right];
                        right += 1;
                    } else {
                        dst[out] = src[left];
                        left += 1;
                    }
                }
                @memcpy(dst[out..][0 .. m - left], src[left..m]);
                out += m - left;
                @memcpy(dst[out..][0 .. b - right], src[right..b]);
            }
        }

        const kernels: Kernels = .{
            .less = less,
            .insertion = insertion,
            .merge_from_left = mergeFromLeft,
            .merge_pass = mergePass,
        };
    };
    // Zero-bit contexts have no address to smuggle through anyopaque; the
    // thunk reconstructs the value instead.
    const view = ErasedView{
        .base = @ptrCast(items.ptr),
        .elem_size = @sizeOf(T),
        .user_ctx = if (comptime @sizeOf(Ctx) == 0) @ptrCast(&zero_bit_sentinel) else @ptrCast(&context),
        .kernels = &thunks.kernels,
    };
    sortView(items.len, &view, @alignOf(T) <= buffer_align);
}

const zero_bit_sentinel: u8 = 0;

fn zeroBitValue(comptime Ctx: type) Ctx {
    comptime std.debug.assert(@sizeOf(Ctx) == 0);
    if (Ctx == void) return;
    return std.mem.zeroes(Ctx);
}

const run_length = 16;
const buffer_bytes = 8192;
const buffer_align = 16;

/// The per-type loops that compare elements.
const Kernels = struct {
    less: *const fn (user_ctx: *const anyopaque, lhs: *const anyopaque, rhs: *const anyopaque) bool,
    /// Sorts `len` elements at `base` by insertion.
    insertion: *const fn (user_ctx: *const anyopaque, base: [*]u8, len: usize) void,
    /// Merges [a, m) and [m, b) through `buf`, which holds the left run.
    merge_from_left: *const fn (user_ctx: *const anyopaque, base: [*]u8, a: usize, m: usize, b: usize, buf: [*]u8) void,
    /// Merges each pair of `width`-long runs of `source` into `dest`.
    merge_pass: *const fn (user_ctx: *const anyopaque, source: [*]u8, dest: [*]u8, len: usize, width: usize) void,
};

const ErasedView = struct {
    base: [*]u8,
    elem_size: usize,
    user_ctx: *const anyopaque,
    kernels: *const Kernels,

    fn at(view: *const ErasedView, index: usize) [*]u8 {
        return view.base + index * view.elem_size;
    }

    fn lessThan(view: *const ErasedView, a: usize, b: usize) bool {
        return view.lessPtr(view.at(a), view.at(b));
    }

    fn lessPtr(view: *const ErasedView, lhs: [*]const u8, rhs: [*]const u8) bool {
        return view.kernels.less(view.user_ctx, @ptrCast(lhs), @ptrCast(rhs));
    }

    fn swap(view: *const ErasedView, a: usize, b: usize) void {
        var tmp: [64]u8 = undefined;
        const lhs = view.at(a);
        const rhs = view.at(b);
        var offset: usize = 0;
        while (offset < view.elem_size) {
            const n = @min(tmp.len, view.elem_size - offset);
            @memcpy(tmp[0..n], lhs[offset..][0..n]);
            @memcpy(lhs[offset..][0..n], rhs[offset..][0..n]);
            @memcpy(rhs[offset..][0..n], tmp[0..n]);
            offset += n;
        }
    }
};

fn sortView(len: usize, view: *const ErasedView, buffer_fits_alignment: bool) void {
    if (len <= run_length) return view.kernels.insertion(view.user_ctx, view.base, len);
    var storage: [buffer_bytes]u8 align(buffer_align) = undefined;
    const buffer: ?[]u8 = if (buffer_fits_alignment and view.elem_size <= buffer_bytes) &storage else null;
    var lo: usize = 0;
    while (lo < len) : (lo += run_length) {
        view.kernels.insertion(view.user_ctx, view.at(lo), @min(run_length, len - lo));
    }
    var width: usize = run_length;
    if (buffer) |buf| {
        const bytes = len * view.elem_size;
        if (bytes <= buf.len) {
            // The whole list fits: merge back and forth between the list and
            // the buffer, moving each element once per level.
            var source = view.base;
            var dest = buf.ptr;
            while (width < len) : (width *= 2) {
                view.kernels.merge_pass(view.user_ctx, source, dest, len, width);
                std.mem.swap([*]u8, &source, &dest);
            }
            if (source != view.base) @memcpy(view.base[0..bytes], source[0..bytes]);
            return;
        }
    }
    while (width < len) : (width *= 2) {
        var start: usize = 0;
        while (start + width < len) : (start += 2 * width) {
            merge(view, start, start + width, @min(start + 2 * width, len), buffer);
        }
    }
}

/// Merges the sorted ranges [a, m) and [m, b), keeping equal elements in
/// their original relative order.
fn merge(view: *const ErasedView, a: usize, m: usize, b: usize, buffer: ?[]u8) void {
    if (!view.lessThan(m, m - 1)) return;
    const size = view.elem_size;
    if (buffer) |buf| {
        if ((m - a) * size <= buf.len) return view.kernels.merge_from_left(view.user_ctx, view.base, a, m, b, buf.ptr);
    }
    symMerge(view, a, m, b, buffer);
}

// Merges the sorted ranges [a, m) and [m, b) in place by splitting them
// around a rotation; smaller merges use the buffer when they fit.
fn symMerge(view: *const ErasedView, a: usize, m: usize, b: usize, buffer: ?[]u8) void {
    std.debug.assert(a < m and m < b);
    if (m - a == 1) {
        // Insert the single left element into the right range.
        var lo = m;
        var hi = b;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (view.lessThan(mid, a)) lo = mid + 1 else hi = mid;
        }
        rotate(view, a, a + 1, lo, buffer);
        return;
    }
    if (b - m == 1) {
        // Insert the single right element into the left range.
        var lo = a;
        var hi = m;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (view.lessThan(m, mid)) hi = mid else lo = mid + 1;
        }
        rotate(view, lo, m, b, buffer);
        return;
    }
    const mid = a + (b - a) / 2;
    const n = mid + m;
    var start: usize = undefined;
    var r: usize = undefined;
    if (m > mid) {
        start = n - b;
        r = mid;
    } else {
        start = a;
        r = m;
    }
    const p = n - 1;
    while (start < r) {
        const c = start + (r - start) / 2;
        if (!view.lessThan(p - c, c)) start = c + 1 else r = c;
    }
    const end = n - start;
    if (start < m and m < end) rotate(view, start, m, end, buffer);
    if (a < start and start < mid) merge(view, a, start, mid, buffer);
    if (mid < end and end < b) merge(view, mid, end, b, buffer);
}

// Rotates [a, b) so that the block starting at m becomes the front.
fn rotate(view: *const ErasedView, a: usize, m: usize, b: usize, buffer: ?[]u8) void {
    if (a == m or m == b) return;
    const size = view.elem_size;
    const left_bytes = (m - a) * size;
    const right_bytes = (b - m) * size;
    if (buffer) |buf| {
        if (left_bytes <= buf.len) {
            @memcpy(buf[0..left_bytes], view.at(a)[0..left_bytes]);
            @memmove(view.at(a)[0..right_bytes], view.at(m)[0..right_bytes]);
            @memcpy((view.at(a) + right_bytes)[0..left_bytes], buf[0..left_bytes]);
            return;
        }
        if (right_bytes <= buf.len) {
            @memcpy(buf[0..right_bytes], view.at(m)[0..right_bytes]);
            @memmove((view.at(a) + right_bytes)[0..left_bytes], view.at(a)[0..left_bytes]);
            @memcpy(view.at(a)[0..right_bytes], buf[0..right_bytes]);
            return;
        }
    }
    // Block exchange (gcd), for runs larger than the buffer.
    var i = m - a;
    var j = b - m;
    while (i != j) {
        if (i > j) {
            swapRange(view, m - i, m, j, buffer);
            i -= j;
        } else {
            swapRange(view, m - i, m + j - i, i, buffer);
            j -= i;
        }
    }
    swapRange(view, m - i, m, i, buffer);
}

/// Swaps the non-overlapping ranges [a, a + n) and [b, b + n), a buffer's
/// worth at a time when there is one.
fn swapRange(view: *const ErasedView, a: usize, b: usize, n: usize, buffer: ?[]u8) void {
    const buf = buffer orelse {
        for (0..n) |i| view.swap(a + i, b + i);
        return;
    };
    const bytes = n * view.elem_size;
    const lhs = view.at(a);
    const rhs = view.at(b);
    var offset: usize = 0;
    while (offset < bytes) {
        const chunk = @min(buf.len, bytes - offset);
        @memcpy(buf[0..chunk], lhs[offset..][0..chunk]);
        @memcpy(lhs[offset..][0..chunk], rhs[offset..][0..chunk]);
        @memcpy(rhs[offset..][0..chunk], buf[0..chunk]);
        offset += chunk;
    }
}

const testing = std.testing;

const TestElem = struct { key: u16, seq: u16 };

fn testElemKeyLess(_: void, lhs: TestElem, rhs: TestElem) bool {
    return lhs.key < rhs.key;
}

// A stable sort's output is uniquely determined by its input, so comparing
// against std.mem.sort element-for-element is an exact oracle.
fn expectMatchesStd(alloc: std.mem.Allocator, items: []const TestElem) !void {
    const expected = try alloc.dupe(TestElem, items);
    defer alloc.free(expected);
    const actual = try alloc.dupe(TestElem, items);
    defer alloc.free(actual);
    std.mem.sort(TestElem, expected, {}, testElemKeyLess);
    sort(TestElem, actual, {}, testElemKeyLess);
    try testing.expectEqualSlices(TestElem, expected, actual);
}

test "matches std.mem.sort across sizes, seeds, and key densities" {
    const alloc = testing.allocator;
    const sizes = [_]usize{ 0, 1, 2, 3, 5, 19, 20, 21, 40, 41, 100, 257, 1000 };
    const key_ranges = [_]u16{ 1, 2, 3, 16, 251, 65535 };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (sizes) |n| {
        for (key_ranges) |range| {
            const items = try alloc.alloc(TestElem, n);
            defer alloc.free(items);
            for (items, 0..) |*item, i| {
                item.* = .{ .key = random.uintLessThan(u16, range), .seq = @intCast(i % 65535) };
            }
            try expectMatchesStd(alloc, items);
        }
    }
}

test "matches std.mem.sort on adversarial patterns" {
    const alloc = testing.allocator;
    const n: usize = 337;
    const items = try alloc.alloc(TestElem, n);
    defer alloc.free(items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(n - 1 - i), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i % 7), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = 42, .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| {
        const key: u16 = if (i < n / 2) @intCast(i) else @intCast(n - i);
        item.* = .{ .key = key, .seq = @intCast(i) };
    }
    try expectMatchesStd(alloc, items);
}

fn permuteAndCheck(alloc: std.mem.Allocator, items: []TestElem, k: usize) !void {
    if (k <= 1) {
        try expectMatchesStd(alloc, items);
        return;
    }
    for (0..k) |i| {
        try permuteAndCheck(alloc, items, k - 1);
        if (k % 2 == 0) {
            std.mem.swap(TestElem, &items[i], &items[k - 1]);
        } else {
            std.mem.swap(TestElem, &items[0], &items[k - 1]);
        }
    }
}

test "every permutation of duplicate-heavy small inputs matches std.mem.sort" {
    const alloc = testing.allocator;
    var n: usize = 1;
    while (n <= 6) : (n += 1) {
        const items = try alloc.alloc(TestElem, n);
        defer alloc.free(items);
        for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i % 3), .seq = @intCast(i) };
        try permuteAndCheck(alloc, items, n);
    }
}

test "runtime context reaches the comparator" {
    const alloc = testing.allocator;
    const Pivot = struct { value: i32 };
    const distanceLess = struct {
        fn less(ctx: Pivot, lhs: i32, rhs: i32) bool {
            return @abs(lhs - ctx.value) < @abs(rhs - ctx.value);
        }
    }.less;
    var prng = std.Random.DefaultPrng.init(0xf00);
    const random = prng.random();
    const expected = try alloc.alloc(i32, 500);
    defer alloc.free(expected);
    for (expected) |*value| value.* = random.intRangeAtMost(i32, -1000, 1000);
    const actual = try alloc.dupe(i32, expected);
    defer alloc.free(actual);
    const pivot = Pivot{ .value = 37 };
    std.mem.sort(i32, expected, pivot, distanceLess);
    sort(i32, actual, pivot, distanceLess);
    try testing.expectEqualSlices(i32, expected, actual);
}

test "odd-sized elements sort correctly" {
    const alloc = testing.allocator;
    const lexLess = struct {
        fn less(_: void, lhs: [7]u8, rhs: [7]u8) bool {
            return std.mem.order(u8, &lhs, &rhs) == .lt;
        }
    }.less;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const expected = try alloc.alloc([7]u8, 300);
    defer alloc.free(expected);
    for (expected) |*elem| {
        random.bytes(elem);
        elem[0] %= 3;
    }
    const actual = try alloc.dupe([7]u8, expected);
    defer alloc.free(actual);
    std.mem.sort([7]u8, expected, {}, lexLess);
    sort([7]u8, actual, {}, lexLess);
    try testing.expectEqualSlices([7]u8, expected, actual);
}

test "slice elements sort by content with duplicates" {
    const alloc = testing.allocator;
    const strLess = struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less;
    const source = [_][]const u8{ "delta", "alpha", "charlie", "alpha", "bravo", "", "charlie", "alpha" };
    const expected = try alloc.dupe([]const u8, &source);
    defer alloc.free(expected);
    const actual = try alloc.dupe([]const u8, &source);
    defer alloc.free(actual);
    std.mem.sort([]const u8, expected, {}, strLess);
    sort([]const u8, actual, {}, strLess);
    try testing.expectEqualSlices([]const u8, expected, actual);
}

const WideElem = struct { key: u16, seq: u16, pad: [60]u8 = @splat(0) };

fn wideElemKeyLess(_: void, lhs: WideElem, rhs: WideElem) bool {
    return lhs.key < rhs.key;
}

fn expectWideMatchesStd(alloc: std.mem.Allocator, items: []const WideElem) !void {
    const expected = try alloc.dupe(WideElem, items);
    defer alloc.free(expected);
    const actual = try alloc.dupe(WideElem, items);
    defer alloc.free(actual);
    std.mem.sort(WideElem, expected, {}, wideElemKeyLess);
    sort(WideElem, actual, {}, wideElemKeyLess);
    try testing.expectEqualSlices(WideElem, expected, actual);
}

test "runs larger than the merge buffer match std.mem.sort" {
    // 2000 elements of 64 bytes make runs far larger than the buffer, so the
    // top merges take the in-place fallback and its rotations.
    const alloc = testing.allocator;
    const n: usize = 2000;
    const items = try alloc.alloc(WideElem, n);
    defer alloc.free(items);
    var prng = std.Random.DefaultPrng.init(0xb16);
    const random = prng.random();
    for ([_]u16{ 2, 37, 65535 }) |range| {
        for (items, 0..) |*item, i| item.* = .{ .key = random.uintLessThan(u16, range), .seq = @intCast(i) };
        try expectWideMatchesStd(alloc, items);
    }
    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i), .seq = @intCast(i) };
    try expectWideMatchesStd(alloc, items);
    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(n - 1 - i), .seq = @intCast(i) };
    try expectWideMatchesStd(alloc, items);
    for (items, 0..) |*item, i| item.* = .{ .key = 7, .seq = @intCast(i) };
    try expectWideMatchesStd(alloc, items);
    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i % 300), .seq = @intCast(i) };
    try expectWideMatchesStd(alloc, items);
}

test "elements larger than the merge buffer match std.mem.sort" {
    const Huge = struct { key: u16, seq: u16, pad: [buffer_bytes]u8 = undefined };
    const hugeLess = struct {
        fn less(_: void, lhs: Huge, rhs: Huge) bool {
            return lhs.key < rhs.key;
        }
    }.less;
    const alloc = testing.allocator;
    const n: usize = 45;
    const expected = try alloc.alloc(Huge, n);
    defer alloc.free(expected);
    var prng = std.Random.DefaultPrng.init(0x4e);
    const random = prng.random();
    for (expected, 0..) |*item, i| {
        item.key = random.uintLessThan(u16, 5);
        item.seq = @intCast(i);
        @memset(&item.pad, @intCast(i));
    }
    const actual = try alloc.dupe(Huge, expected);
    defer alloc.free(actual);
    std.mem.sort(Huge, expected, {}, hugeLess);
    sort(Huge, actual, {}, hugeLess);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.key, a.key);
        try testing.expectEqual(e.seq, a.seq);
        try testing.expectEqualSlices(u8, &e.pad, &a.pad);
    }
}

test "over-aligned elements match std.mem.sort without the buffer" {
    const Aligned = struct { key: u16 align(64), seq: u16 };
    const alignedLess = struct {
        fn less(_: void, lhs: Aligned, rhs: Aligned) bool {
            return lhs.key < rhs.key;
        }
    }.less;
    const alloc = testing.allocator;
    const n: usize = 500;
    const expected = try alloc.alloc(Aligned, n);
    defer alloc.free(expected);
    var prng = std.Random.DefaultPrng.init(0xa1);
    const random = prng.random();
    for (expected, 0..) |*item, i| item.* = .{ .key = random.uintLessThan(u16, 40), .seq = @intCast(i) };
    const actual = try alloc.dupe(Aligned, expected);
    defer alloc.free(actual);
    std.mem.sort(Aligned, expected, {}, alignedLess);
    sort(Aligned, actual, {}, alignedLess);
    try testing.expectEqualSlices(Aligned, expected, actual);
}
