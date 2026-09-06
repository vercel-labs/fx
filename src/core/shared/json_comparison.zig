const std = @import("std");

pub fn serializedEqual(alloc: std.mem.Allocator, lhs: []const u8, rhs: []const u8) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, lhs, rhs)) return true;
    var left = std.json.parseFromSlice(std.json.Value, alloc, lhs, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer left.deinit();
    var right = std.json.parseFromSlice(std.json.Value, alloc, rhs, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer right.deinit();

    const Frame = struct { left: std.json.Value, right: std.json.Value, index: usize = 0 };
    var pending: std.ArrayList(Frame) = .empty;
    defer pending.deinit(alloc);
    try pending.append(alloc, .{ .left = left.value, .right = right.value });
    while (pending.items.len > 0) {
        const frame = &pending.items[pending.items.len - 1];
        if (std.meta.activeTag(frame.left) != std.meta.activeTag(frame.right)) return false;
        switch (frame.left) {
            .null => {},
            .bool => |value| if (value != frame.right.bool) return false,
            .integer => |value| if (value != frame.right.integer) return false,
            .float => |value| if (value != frame.right.float) return false,
            .number_string => |value| if (!std.mem.eql(u8, value, frame.right.number_string)) return false,
            .string => |value| if (!std.mem.eql(u8, value, frame.right.string)) return false,
            .array => |values| {
                if (values.items.len != frame.right.array.items.len) return false;
                if (frame.index < values.items.len) {
                    const next = Frame{ .left = values.items[frame.index], .right = frame.right.array.items[frame.index] };
                    frame.index += 1;
                    try pending.append(alloc, next);
                    continue;
                }
            },
            .object => |fields| {
                if (fields.count() != frame.right.object.count()) return false;
                if (frame.index < fields.count()) {
                    const value = frame.right.object.get(fields.keys()[frame.index]) orelse return false;
                    const next = Frame{ .left = fields.values()[frame.index], .right = value };
                    frame.index += 1;
                    try pending.append(alloc, next);
                    continue;
                }
            },
        }
        _ = pending.pop();
    }
    return true;
}

test "serialized JSON equality preserves typed values and object order independence" {
    const cases = [_]struct { left: []const u8, right: []const u8, equal: bool }{
        .{ .left = "{}", .right = " { } ", .equal = true },
        .{ .left = "{\"a\":1,\"b\":[true,null]}", .right = "{\"b\":[true,null],\"a\":1}", .equal = true },
        .{ .left = "{\"a\":\"A\"}", .right = "{\"a\":\"\\u0041\"}", .equal = true },
        .{ .left = "[1,2]", .right = "[2,1]", .equal = false },
        .{ .left = "{\"a\":1}", .right = "{\"b\":1}", .equal = false },
        .{ .left = "1", .right = "1.0", .equal = false },
        .{ .left = "null", .right = "false", .equal = false },
        .{ .left = "{]", .right = "{}", .equal = false },
        .{ .left = "{]", .right = "{]", .equal = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.equal, try serializedEqual(std.testing.allocator, case.left, case.right));
}

fn expectComparisonAllocations(alloc: std.mem.Allocator) !void {
    try std.testing.expect(try serializedEqual(alloc, "{\"a\":[1,{\"b\":true}]}", " { \"a\" : [1, {\"b\":true}] } "));
    try std.testing.expect(!try serializedEqual(alloc, "{\"a\":[1,{\"b\":true}]}", "{\"a\":[1,{\"b\":false}]}"));
}

test "serialized JSON equality releases comparison allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectComparisonAllocations, .{});
    try std.testing.expect(try serializedEqual(std.testing.failing_allocator, "{}", "{}"));
}

test "serialized JSON equality traverses nested values with owned scratch" {
    const alloc = std.testing.allocator;
    const depth = 256;
    var left: std.Io.Writer.Allocating = .init(alloc);
    defer left.deinit();
    var right: std.Io.Writer.Allocating = .init(alloc);
    defer right.deinit();
    for (0..depth) |_| {
        try left.writer.writeByte('[');
        try right.writer.writeAll("[ ");
    }
    try left.writer.writeByte('1');
    try right.writer.writeByte('1');
    for (0..depth) |_| {
        try left.writer.writeByte(']');
        try right.writer.writeAll(" ]");
    }
    try std.testing.expect(try serializedEqual(alloc, left.written(), right.written()));
}
