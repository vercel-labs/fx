const std = @import("std");

/// Comptime string interning for static lookup tables.
///
/// A `[]const u8` table entry costs 16 bytes of rodata (8-byte pointer,
/// 8-byte length) and drags its table into a rebased segment. An interned
/// Ref packs a 24-bit blob offset and an 8-bit length into one u32 and
/// needs no relocation, so each entry costs 4 bytes. Tables keep their
/// natural literal form: the pool is built at comptime from the same
/// literals, deduplicated by content.
///
/// Limits by construction: one blob holds at most 16 MiB and each interned
/// string at most 255 bytes; both are comptime errors when exceeded.
pub fn Interned(comptime strings: []const []const u8) type {
    return struct {
        const Data = struct {
            blob: []const u8,
            raws: [strings.len]u32,
        };
        const data = blk: {
            @setEvalBranchQuota(strings.len * strings.len + 10_000);
            var acc: []const u8 = "";
            var offs: [strings.len]u32 = undefined;
            var raws: [strings.len]u32 = undefined;
            for (strings, 0..) |s, i| {
                if (s.len > 255)
                    @compileError("interned string exceeds 255 bytes: " ++ s);
                var found: ?u32 = null;
                for (strings[0..i], 0..) |prev, j| {
                    if (std.mem.eql(u8, prev, s)) {
                        found = offs[j];
                        break;
                    }
                }
                const off = found orelse @as(u32, @intCast(acc.len));
                offs[i] = off;
                if (found == null) acc = acc ++ s;
                raws[i] = (off << 8) | @as(u32, @intCast(s.len));
            }
            if (acc.len > 0xff_ffff)
                @compileError("interned blob exceeds 24-bit offsets");
            break :blk Data{ .blob = acc, .raws = raws };
        };

        pub const blob = data.blob;

        pub const Ref = struct {
            raw: u32,

            pub fn get(self: Ref) []const u8 {
                return blob[self.raw >> 8 ..][0..self.len()];
            }

            pub fn len(self: Ref) usize {
                return self.raw & 0xff;
            }
        };

        comptime {
            std.debug.assert(@sizeOf(Ref) == 4);
        }

        /// Every interned string, in declaration order.
        pub const all = blk: {
            var out: [strings.len]Ref = undefined;
            for (data.raws, 0..) |raw, i| out[i] = .{ .raw = raw };
            break :blk out;
        };

        /// Ref for one literal; comptime error when it is not in the pool.
        /// Comptime-only: call it from comptime context, never at runtime.
        pub fn ref(comptime s: []const u8) Ref {
            @setEvalBranchQuota(strings.len * 300 + 10_000);
            for (strings, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, s)) return .{ .raw = data.raws[i] };
            }
            @compileError("string is not in the pool: " ++ s);
        }

        /// Static array of Refs for a sublist of pool literals; use as
        /// `Pool.List(.{ "a", "b" }).items[0..]` where a slice is needed.
        pub fn List(comptime strs: anytype) type {
            return struct {
                pub const items = blk: {
                    var out: [strs.len]Ref = undefined;
                    for (strs, 0..) |s, i| out[i] = ref(s);
                    break :blk out;
                };
            };
        }
    };
}

const test_pool = Interned(&.{ "alpha", "beta", "alpha", "gamma", "beta" });
const test_pool_small = Interned(&.{ "one", "two", "three" });

test "interned pool roundtrips strings and dedups by content" {
    const pool = test_pool;
    try std.testing.expectEqualStrings("alphabetagamma", pool.blob);
    try std.testing.expectEqual(@as(usize, 5), pool.all.len);
    try std.testing.expectEqualStrings("alpha", pool.all[0].get());
    try std.testing.expectEqualStrings("beta", pool.all[1].get());
    try std.testing.expectEqualStrings("alpha", pool.all[2].get());
    try std.testing.expectEqualStrings("gamma", pool.all[3].get());
    try std.testing.expectEqual(@as(usize, 5), pool.all[0].len());
    // duplicates share blob storage
    try std.testing.expectEqual(pool.all[0].raw, pool.all[2].raw);
    try std.testing.expectEqual(pool.all[1].raw, pool.all[4].raw);
    // ref lookup resolves to the same storage; ref is comptime-only
    const alpha = comptime test_pool.ref("alpha");
    const gamma = comptime test_pool.ref("gamma");
    try std.testing.expectEqual(pool.all[0].raw, alpha.raw);
    try std.testing.expectEqualStrings("gamma", gamma.get());
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(pool.Ref));
}

test "interned pool lists expose static ref arrays" {
    const pool = test_pool_small;
    const pair = pool.List(.{ "three", "one" });
    try std.testing.expectEqual(@as(usize, 2), pair.items.len);
    try std.testing.expectEqualStrings("three", pair.items[0].get());
    try std.testing.expectEqualStrings("one", pair.items[1].get());
}
