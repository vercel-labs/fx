const std = @import("std");
const host_target = @import("../hosts/target.zig");

/// wasm32 lacks 64-bit atomics, so `std.atomic.Value(u64)` fails to compile
/// there. WASM builds run single-threaded, so a plain value with the same
/// API is sound on that target while native builds keep real atomics.
pub fn Value(comptime T: type) type {
    if (!host_target.is_wasm) return std.atomic.Value(T);
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub fn load(self: *const Self, comptime _: std.lang.AtomicOrder) T {
            return self.raw;
        }

        pub fn store(self: *Self, value: T, comptime _: std.lang.AtomicOrder) void {
            self.raw = value;
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime _: std.lang.AtomicOrder) T {
            const previous = self.raw;
            self.raw +%= operand;
            return previous;
        }

        pub fn cmpxchgWeak(
            self: *Self,
            expected: T,
            new: T,
            comptime _: std.lang.AtomicOrder,
            comptime _: std.lang.AtomicOrder,
        ) ?T {
            if (self.raw != expected) return self.raw;
            self.raw = new;
            return null;
        }
    };
}

test "plain value matches the atomic API it replaces" {
    var value: Value(u64) = .init(5);
    try std.testing.expectEqual(@as(u64, 5), value.load(.acquire));
    value.store(7, .release);
    try std.testing.expectEqual(@as(u64, 7), value.fetchAdd(2, .monotonic));
    try std.testing.expectEqual(@as(u64, 9), value.load(.acquire));
    try std.testing.expectEqual(@as(?u64, 9), value.cmpxchgWeak(1, 3, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(?u64, null), value.cmpxchgWeak(9, 3, .acq_rel, .acquire));
    try std.testing.expectEqual(@as(u64, 3), value.load(.acquire));
}
