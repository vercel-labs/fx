// Compile-checked Zig 0.17 examples for the zig skill. Run: zig test examples.zig
// Passes on Zig 0.17.0 and 0.17.1.

const std = @import("std");
const builtin = @import("builtin");

// `**` replacement for repeated comptime strings.
inline fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count:0]u8 {
    return comptime blk: {
        var bytes: [text.len * count:0]u8 = @splat(0);
        for (0..count) |i| @memcpy(bytes[i * text.len ..][0..text.len], text);
        const final = bytes;
        break :blk &final;
    };
}

test "array and string repetition without **" {
    const zeros: [8]u8 = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), zeros[7]);
    const rule: [40]u8 = @splat('-');
    try std.testing.expectEqual(@as(usize, 40), rule.len);
    try std.testing.expectEqualStrings("abab", repeat("ab", 2));
}

test "SafeAllocator and BufferFirstAllocator" {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();
    const s = try gpa.print("{s}={d}", .{ "k", 3 });
    try std.testing.expectEqualStrings("k=3", s);
    gpa.free(s);
    var stack_buf: [64]u8 = undefined;
    var first: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
    const a = first.allocator();
    const small = try a.alloc(u8, 16);
    a.free(small);
    try std.testing.expectEqual(@as(usize, 0), safe.deinit());
}

// The entry point from SKILL.md. init.gpa is a SafeAllocator in Debug and
// ReleaseSafe builds; init.io is the process's std.Io.Threaded.
fn mainExample(init: std.process.Init) !void {
    const greeting = try init.gpa.print("hello, {s}", .{"zig"});
    defer init.gpa.free(greeting);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{greeting});
    try stdout.interface.flush();
}

test "the std.process.Init entry point compiles" {
    // Taking the address forces semantic analysis of the whole body.
    _ = &mainExample;
}

const Level = enum(u8) { low = 1, high = 2 };

test "backingInt, fromBackingInt, divCeil" {
    try std.testing.expectEqual(@as(u8, 2), @backingInt(Level.high));
    const wide: usize = 1;
    const level: Level = @fromBackingInt(@intCast(wide));
    try std.testing.expectEqual(Level.low, level);
    try std.testing.expectEqual(@as(u64, 4), @divCeil(@as(u64, 10), 3));
    try std.testing.expectEqual(@as(i32, -1), @divCeil(@as(i32, -5), 3));
}

test "comptime-length slices coerce to arrays" {
    const slice: []const u16 = &.{ 1, 2, 3 };
    const array: [3]u16 = slice.*;
    const array_ptr: *const [3]u16 = slice;
    try std.testing.expectEqual(@as(u16, 3), array[2] + array_ptr[0] - 1);
    var buf = [_]u8{ 1, 2, 3, 4, 5 };
    var start: usize = 1;
    _ = &start;
    const window = buf[start..][0..2];
    try std.testing.expectEqual(*[2]u8, @TypeOf(window));
}

const TwoBytes = extern struct { b0: u8, b1: u8 };

test "extern struct punning uses @ptrCast" {
    const bytes: TwoBytes = .{ .b0 = 0x12, .b1 = 0xAB };
    const int_ptr: *align(1) const u16 = @ptrCast(&bytes);
    try std.testing.expectEqual(@as(u16, 0xAB12), int_ptr.*);
}

test "last, print, mem.print, find, path, target, optimize" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try std.testing.expectEqual(@as(?u8, null), list.last());
    try list.appendSlice(gpa, "ab");
    try std.testing.expectEqual(@as(u8, 'b'), list.last().?);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("x=1", try std.mem.print(&buf, "x={d}", .{1}));
    try std.testing.expectError(error.NoSpaceLeft, std.mem.print(buf[0..1], "long", .{}));
    try std.testing.expectEqual(@as(?usize, 1), std.mem.findScalar(u8, "a,b", ','));
    try std.testing.expectEqual(@as(?usize, 3), std.mem.findScalarLast(u8, "a/b/c", '/'));
    const joined = try std.Io.Dir.path.join(gpa, &.{ "/home", "x" });
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("/home/x", joined);
    const resolved = try std.Io.Dir.path.resolveAlloc(gpa, &.{ "/a/b", "../c" });
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("/a/c", resolved);
    _ = builtin.target.os.tag;
    try std.testing.expect(builtin.optimize.runtimeSafety() == (builtin.optimize == .debug or builtin.optimize == .safe));
    const label: []const u8 = switch (builtin.optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
    try std.testing.expect(label.len > 0);
    try std.testing.expect(std.mem.containsAtLeastScalar(u8, "banana", 'a', 3));
}

test "struct-of-arrays reflection" {
    const S = struct { a: u8, b: u16 };
    const info = @typeInfo(S).@"struct";
    try std.testing.expectEqual(@as(usize, 2), info.field_names.len);
    try std.testing.expectEqualStrings("b", info.field_names[1]);
    try std.testing.expectEqual(u16, info.field_types[1]);
}

fn decodeOne(sequence: []const u8) error{InvalidUtf8}!u21 {
    if (sequence.len == 0) return error.InvalidUtf8;
    const len = std.unicode.utf8ByteSequenceLength(sequence[0]) catch return error.InvalidUtf8;
    if (len != sequence.len) return error.InvalidUtf8;
    return switch (len) {
        1 => sequence[0],
        2 => std.unicode.utf8Decode2(sequence[0..2].*) catch error.InvalidUtf8,
        3 => std.unicode.utf8Decode3(sequence[0..3].*) catch error.InvalidUtf8,
        4 => std.unicode.utf8Decode4(sequence[0..4].*) catch error.InvalidUtf8,
        else => unreachable,
    };
}

test "validated single-sequence UTF-8 decode" {
    try std.testing.expectEqual(@as(u21, 0xe9), try decodeOne("\xc3\xa9"));
    try std.testing.expectError(error.InvalidUtf8, decodeOne("\xe4\x80"));
}

test "zon parse with struct args" {
    const Config = struct { name: []const u8, port: u16 };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const cfg = try std.zon.parse.fromSlice(Config, .{
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .source = ".{ .name = \"fx\", .port = 8 }",
        .diagnostics = &diag,
    });
    try std.testing.expectEqualStrings("fx", cfg.name);
    try std.testing.expectEqual(@as(u16, 8), cfg.port);
}
